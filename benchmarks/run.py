"""Paired Ruby SDK measurements using head-side fixtures and isolated installed gems."""

import argparse
import json
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import uuid
from pathlib import Path

from fixtures import USERS, definitions, digest, workloads
from server import BenchmarkServer

HERE = Path(__file__).resolve().parent
WORKER = HERE / "worker.rb"
TIMEOUT = 120
MAX_TIMEOUTS = 2


def git(directory, *args):
    return subprocess.check_output(
        ["git", "-C", str(directory), *args], text=True
    ).strip()


def source_digest():
    return digest(
        {
            p.name: digest(p.read_bytes())
            for p in sorted(HERE.iterdir())
            if p.suffix in (".rb", ".py", ".json")
        }
    )


def load_shards():
    manifest = json.loads((HERE / "shards.json").read_text())
    if manifest.get("manifest_version") != 1 or manifest.get("sdk") != "posthog-ruby":
        raise ValueError("Invalid shard manifest")
    shards = {}
    seen = set()
    for shard in manifest["shards"]:
        identity, members = shard["id"], shard["workloads"]
        if (
            not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", identity)
            or identity in shards
            or not members
        ):
            raise ValueError("Invalid shard identity")
        if len(set(members)) != len(members) or seen.intersection(members):
            raise ValueError("Duplicate shard workloads")
        seen.update(members)
        shards[identity] = members
    if not 0 < len(shards) <= 16 or any(
        seen != {w["id"] for w in workloads(smoke)} for smoke in (True, False)
    ):
        raise ValueError("Shard manifest must partition full and smoke inventories")
    return shards


def worker_env(installation, directory):
    info = json.loads((installation / "installation.json").read_text())
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("BUNDLE_", "RUBY", "GEM_"))
    }
    for key in (
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "POSTHOG_RELEASE_ID",
    ):
        env.pop(key, None)
    env.update(
        GEM_HOME=info["gem_home"],
        GEM_PATH=os.pathsep.join([info["gem_home"], info["gem_path"]]),
        RUBYOPT="",
        BENCHMARK_SDK_VERSION=info["sdk_version"],
        BENCHMARK_CONCURRENT_VERSION=info["concurrent_version"],
        TMPDIR=str(directory),
        HOME=str(directory),
    )
    return env


def run_worker(installation, spec, measurement_pass, timeout=TIMEOUT):
    with tempfile.TemporaryDirectory(
        prefix="ruby-benchmark-"
    ) as scratch, BenchmarkServer(spec) as server:
        scratch = Path(scratch)
        input_path, output = scratch / "spec.json", scratch / "result.json"
        input_path.write_text(json.dumps({**spec, "pass": measurement_pass}))
        process = subprocess.Popen(
            ["ruby", str(WORKER), str(input_path), server.url, str(output)],
            cwd=scratch,
            env=worker_env(installation, scratch),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        buffers = {"stdout": bytearray(), "stderr": bytearray()}

        def read_log(stream, target):
            with stream:
                while chunk := stream.read(4096):
                    target.extend(chunk)
                    del target[:-65536]

        readers = [
            threading.Thread(
                target=read_log, args=(getattr(process, name), buffer), daemon=True
            )
            for name, buffer in buffers.items()
        ]
        for reader in readers:
            reader.start()
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        for reader in readers:
            reader.join(timeout=2)
        logs = {
            name: data.decode("utf-8", errors="replace")
            for name, data in buffers.items()
        }
        if process.returncode == 0 and output.exists() and not timed_out:
            if output.stat().st_size > 2 * 1024 * 1024:
                raise ValueError("Worker result exceeds size limit")
            result = json.loads(output.read_text())
            operations = (
                spec.get("allocation_operations", spec["operations"])
                if measurement_pass == "allocation"
                else spec["operations"]
            )
            if (
                result.get("pass") != measurement_pass
                or result.get("operations") != operations
                or result.get("status") != "ok"
            ):
                raise ValueError("Worker result identity differs")
            return {**result, **logs}
        return {
            "status": "timeout" if timed_out else "error",
            "pass": measurement_pass,
            "code": process.returncode,
            "error": (
                "Worker exceeded deadline"
                if timed_out
                else "Worker did not complete; exit alone does not establish OOM"
            ),
            **logs,
        }


def document_for(directory, installation, role, pair_id, suite, shard):
    with tempfile.TemporaryDirectory(prefix="ruby-benchmark-describe-") as scratch:
        execution = json.loads(
            subprocess.check_output(
                ["ruby", str(WORKER), "--describe"],
                cwd=scratch,
                env=worker_env(installation, scratch),
                text=True,
                timeout=TIMEOUT,
            )
        )
    # Fingerprint the installed build, independently of package version.
    installed = Path(execution["entry"])
    execution.update(
        pair_id=pair_id,
        runtime_flags=[],
        build_digest=digest(
            {
                str(p.relative_to(installed)): digest(p.read_bytes())
                for p in sorted((installed / "lib").rglob("*.rb"))
            }
        ),
        dependency_lock_digest=digest((directory / "Gemfile.lock").read_bytes()),
        runner_class=(
            "github-hosted-or-self-hosted" if os.getenv("RUNNER_NAME") else "local"
        ),
        runner_image=os.getenv("ImageVersion"),
        resource_limits={
            "worker_timeout_ms": TIMEOUT * 1000,
            "max_worker_timeouts": MAX_TIMEOUTS,
            "process_rss_limit_bytes": None,
        },
    )
    if shard:
        execution["shard_id"] = shard
    return {
        "schema_version": 1,
        "sdk": "posthog-ruby",
        "revision": {
            "role": role,
            "commit": git(directory, "rev-parse", "HEAD"),
            "dirty": bool(git(directory, "status", "--porcelain")),
        },
        "suite": suite,
        "execution": execution,
        "benchmarks": [],
    }


def append_sample(record, raw, repetition):
    record["runs"].append({"repetition": repetition, **raw})
    if raw["status"] != "ok":
        record["status"] = raw["status"]
        return

    def add(name, unit, method, value):
        if not math.isfinite(value) or value < 0:
            raise ValueError(f"Invalid metric: {name}")
        metric = next((m for m in record["metrics"] if m["id"] == name), None)
        if metric is None:
            metric = {
                "id": name,
                "unit": unit,
                "method": method,
                "quality": "measured",
                "direction": "lower",
                "status": "ok",
                "samples": [],
            }
            record["metrics"].append(metric)
        metric["samples"].append(
            {"repetition": repetition, "value": value, "operations": raw["operations"]}
        )

    def unsupported(name, unit, reason):
        if not any(m["id"] == name for m in record["metrics"]):
            record["metrics"].append(
                {"id": name, "unit": unit, "status": "unsupported", "reason": reason}
            )

    if raw["pass"] == "timing":
        add(
            "elapsed_time_per_op",
            "ns/op",
            "Process.clock_gettime.CLOCK_MONOTONIC",
            raw["elapsed_time_per_op"],
        )
        enqueue = record["parameters"]["mode"] == "capture"
        add(
            "caller_thread_cpu_time_per_op" if enqueue else "process_cpu_time_per_op",
            "ns/op",
            (
                "Process.clock_gettime.CLOCK_THREAD_CPUTIME_ID"
                if enqueue
                else "Process.clock_gettime.CLOCK_PROCESS_CPUTIME_ID"
            ),
            raw["cpu_time_per_op"],
        )
        if enqueue:
            for name, unit in (
                ("allocated_bytes_per_op", "bytes/op"),
                ("allocations_per_op", "count/op"),
            ):
                unsupported(
                    name,
                    unit,
                    "Background serialization has no public enqueue completion boundary; use completed-delivery workloads for process-wide allocation counts.",
                )
    elif raw["pass"] == "allocation":
        add(
            "allocations_per_op",
            "count/op",
            "GC.stat.total_allocated_objects; all worker threads; Ruby objects excluding native malloc",
            raw["allocated_objects"] / raw["operations"],
        )
        unsupported(
            "allocated_bytes_per_op",
            "bytes/op",
            "Ruby has no cumulative allocated-byte counter here; retained ObjectSpace bytes are not allocation volume.",
        )
    elif raw["pass"] == "memory":
        for name, value in (
            ("idle_process_rss", raw["before"]["rss"]),
            ("observed_workload_peak_rss", raw["observed_peak_rss"]),
            ("post_settling_process_rss", raw["after_settling"]["rss"]),
        ):
            add(
                name,
                "bytes",
                "proc.status.VmRSS or ps.rss; operation checkpoints",
                value,
            )
        add(
            "post_settling_heap_used",
            "bytes",
            "ObjectSpace.memsize_of_all; retained live objects, not allocator arena size",
            raw["after_settling"]["heap_used"],
        )
        if raw["process_lifetime_peak_rss"] is not None:
            add(
                "process_lifetime_peak_rss",
                "bytes",
                "proc.status.VmHWM; includes setup and warmup",
                raw["process_lifetime_peak_rss"],
            )
        else:
            unsupported(
                "process_lifetime_peak_rss",
                "bytes",
                "No process-lifetime RSS high-water counter on this platform; not inferred from checkpoints.",
            )


def main(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("base", "head", "build_directory", "output"):
        parser.add_argument("--" + name.replace("_", "-"), type=Path, required=True)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--repetitions", type=int, default=6, choices=range(1, 31))
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--shard")
    selection.add_argument("--filter", default="")
    options = parser.parse_args(args)
    shards = load_shards()
    if options.shard and options.shard not in shards:
        parser.error("Unknown shard")
    specs = (
        [s for s in workloads(options.smoke) if s["id"] in shards[options.shard]]
        if options.shard
        else [s for s in workloads(options.smoke) if s["id"].startswith(options.filter)]
    )
    if not specs:
        parser.error("No matching workloads")
    suite = {
        "id": "ruby-sdk-performance",
        "version": 2,
        "specification": "sdk-benchmarks/v1",
        "source_commit": git(HERE, "rev-parse", "HEAD"),
        "source_digest": source_digest(),
        "profile": "smoke" if options.smoke else "full",
        "repetitions": options.repetitions,
        "transport": "coordinator-owned loopback HTTP receiver; uncompressed; native batch byte limits retained",
        "capture": {
            "batch_size": 100000,
            "max_queue_size": 100001,
            "flush_interval_seconds": 3600,
        },
        "warmup": "two refreshes; otherwise min(operations, 32 for 1000 flags or 160); verified reset and generation zero restored",
        "settling": "two GC.start calls separated by Thread.pass; no forced GC in measured work",
        "memory_sampling": "after every 32 load operations, each refresh, each 100 captures, and final work; ObjectSpace and RSS snapshots",
        "allocation_scope": "GC.stat Ruby object allocations across worker threads; excludes coordinator receiver and native malloc",
    }
    pair_id = str(uuid.uuid4())
    directories = {"base": options.base.resolve(), "head": options.head.resolve()}
    builds = {role: options.build_directory.resolve() / role for role in directories}
    documents = {
        role: document_for(directory, builds[role], role, pair_id, suite, options.shard)
        for role, directory in directories.items()
    }
    for key in ("runtime", "runtime_version", "measurement_tools", "os", "arch"):
        if documents["base"]["execution"][key] != documents["head"]["execution"][key]:
            raise ValueError(f"Base/head {key} differ")
    options.output.mkdir(parents=True, exist_ok=True)

    def save():
        for role, document in documents.items():
            temporary = options.output / f"{role}.json.tmp"
            temporary.write_text(json.dumps(document, allow_nan=False, indent=2) + "\n")
            temporary.replace(options.output / f"{role}.json")

    failures = timeouts = 0
    for spec in specs:
        records = {}
        for role in directories:
            record = {
                "id": spec["id"],
                "parameters": spec,
                "fixture_digest": digest(
                    {
                        "spec": spec,
                        "users": USERS,
                        "definitions": (
                            definitions(spec["flag_count"])
                            if "flag_count" in spec
                            else None
                        ),
                    }
                ),
                "status": "ok",
                "metrics": [],
                "runs": [],
            }
            records[role] = record
            documents[role]["benchmarks"].append(record)
        for repetition in range(options.repetitions):
            for measurement_pass in spec["passes"]:
                for role in ("head", "base") if repetition % 2 else ("base", "head"):
                    raw = run_worker(builds[role], spec, measurement_pass)
                    append_sample(records[role], raw, repetition)
                    failures += raw["status"] != "ok"
                    timeouts += raw["status"] == "timeout"
                    print(
                        f'{spec["id"]} {measurement_pass} {repetition + 1}/{options.repetitions} {role}: {raw["status"]}',
                        flush=True,
                    )
                    save()
                if timeouts >= MAX_TIMEOUTS:
                    return 1
            if any(record["status"] != "ok" for record in records.values()):
                break
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
