"""Coordinator, fixture and real public-entry controls. No external service required."""

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.request import Request, urlopen

import fixtures
import run
from server import BenchmarkServer

HERE = Path(__file__).resolve().parent


class Controls(unittest.TestCase):
    def test_inventory_and_partition(self):
        shards = run.load_shards()
        self.assertEqual(len(shards), 4)
        for smoke in (True, False):
            specs = fixtures.workloads(smoke)
            self.assertEqual(len(specs), 20)
            self.assertEqual(len({s["id"] for s in specs}), 20)
            self.assertEqual(
                set().union(*(set(w) for w in shards.values())),
                {s["id"] for s in specs},
            )
            self.assertEqual(len([s for s in specs if s["mode"] == "single"]), 9)
            for spec in specs:
                (
                    self.assertEqual(spec["operations"], 200 if smoke else 1000)
                    if "payload_bytes" in spec
                    else None
                )
                if spec["mode"] == "drain":
                    self.assertEqual(
                        spec["flush_every"],
                        (
                            100
                            if spec["drain_strategy"] == "steady"
                            else spec["operations"]
                        ),
                    )
                    self.assertEqual(spec["passes"], ["timing", "allocation", "memory"])

    def test_flags_fixtures(self):
        doc = fixtures.definitions(1000)
        self.assertEqual(len(doc["flags"]), 1000)
        self.assertEqual(len(fixtures.USERS), 16)
        self.assertEqual(doc["flags"][9]["active"], False)
        self.assertEqual(len(doc["flags"][6]["filters"]["groups"]), 8)
        self.assertEqual(len(doc["flags"][7]["filters"]["groups"]), 8)
        self.assertNotEqual(
            fixtures.definitions(1000, 0), fixtures.definitions(1000, 1)
        )
        self.assertEqual(
            fixtures.definitions(1000, 0),
            fixtures.definitions(1000, 2)
            | {"flags": fixtures.definitions(1000, 0)["flags"]},
        )

    def test_source_identity_includes_manifest(self):
        before = run.source_digest()
        original = (HERE / "shards.json").read_bytes()
        real = Path.read_bytes
        with patch.object(
            Path,
            "read_bytes",
            lambda p: original + b" " if p.name == "shards.json" else real(p),
        ):
            self.assertNotEqual(run.source_digest(), before)

    def test_bad_manifests_rejected(self):
        manifest = json.loads((HERE / "shards.json").read_text())
        for mutate in (
            lambda m: m["shards"][0]["workloads"].pop(),
            lambda m: m["shards"][1]["workloads"].append(
                m["shards"][0]["workloads"][0]
            ),
            lambda m: m["shards"][0].update(id="../unsafe"),
        ):
            changed = copy.deepcopy(manifest)
            mutate(changed)
            with patch.object(
                Path, "read_text", return_value=json.dumps(changed)
            ), self.assertRaises(ValueError):
                run.load_shards()

    def test_metrics_keep_failures_and_unsupported_distinct(self):
        record = {
            "status": "ok",
            "parameters": {"mode": "all"},
            "runs": [],
            "metrics": [],
        }
        run.append_sample(
            record,
            {
                "status": "ok",
                "pass": "allocation",
                "operations": 10,
                "allocated_objects": 100,
            },
            0,
        )
        values = {m["id"]: m for m in record["metrics"]}
        self.assertEqual(values["allocations_per_op"]["samples"][0]["value"], 10)
        self.assertEqual(values["allocated_bytes_per_op"]["status"], "unsupported")
        run.append_sample(record, {"status": "timeout", "pass": "allocation"}, 1)
        self.assertEqual(record["status"], "timeout")
        self.assertEqual(len(values["allocations_per_op"]["samples"]), 1)

    def test_invalid_counter_rejected(self):
        record = {
            "status": "ok",
            "parameters": {"mode": "all"},
            "runs": [],
            "metrics": [],
        }
        with self.assertRaises(ValueError):
            run.append_sample(
                record,
                {
                    "status": "ok",
                    "pass": "allocation",
                    "operations": 1,
                    "allocated_objects": -1,
                },
                0,
            )

    def test_enqueue_uses_caller_thread_cpu(self):
        record = {
            "status": "ok",
            "parameters": {"mode": "capture"},
            "runs": [],
            "metrics": [],
        }
        run.append_sample(
            record,
            {
                "status": "ok",
                "pass": "timing",
                "operations": 1,
                "elapsed_time_per_op": 2,
                "cpu_time_per_op": 1,
            },
            0,
        )
        self.assertEqual(
            {m["id"] for m in record["metrics"]},
            {
                "elapsed_time_per_op",
                "caller_thread_cpu_time_per_op",
                "allocations_per_op",
                "allocated_bytes_per_op",
            },
        )

    def test_timeout_finishes_pair_and_stops(self):
        doc = {
            "schema_version": 1,
            "execution": {
                k: "same"
                for k in (
                    "runtime",
                    "runtime_version",
                    "measurement_tools",
                    "os",
                    "arch",
                )
            },
            "benchmarks": [],
        }
        calls = []

        def fake_worker(installation, spec, measurement_pass):
            calls.append(installation.name)
            return {"status": "timeout", "pass": measurement_pass}

        with tempfile.TemporaryDirectory() as t, patch.object(
            run, "document_for", side_effect=lambda *a: copy.deepcopy(doc)
        ), patch.object(run, "run_worker", side_effect=fake_worker):
            code = run.main(
                [
                    "--base",
                    t,
                    "--head",
                    t,
                    "--build-directory",
                    t,
                    "--output",
                    t,
                    "--shard",
                    "flags-single",
                ]
            )
            self.assertEqual(code, 1)
            self.assertEqual(calls, ["base", "head"])
            saved = json.loads((Path(t) / "head.json").read_text())
            self.assertEqual(saved["benchmarks"][0]["status"], "timeout")

    def test_alternating_pairs(self):
        doc = {
            "execution": {
                k: "same"
                for k in (
                    "runtime",
                    "runtime_version",
                    "measurement_tools",
                    "os",
                    "arch",
                )
            },
            "benchmarks": [],
        }
        calls = []

        def worker(installation, spec, measurement_pass):
            calls.append(installation.name)
            return {
                "status": "ok",
                "pass": measurement_pass,
                "operations": 1,
                "elapsed_time_per_op": 1,
                "cpu_time_per_op": 1,
                "allocated_objects": 1,
            }

        with tempfile.TemporaryDirectory() as t, patch.object(
            run, "document_for", side_effect=lambda *a: copy.deepcopy(doc)
        ), patch.object(run, "run_worker", side_effect=worker):
            self.assertEqual(
                run.main(
                    [
                        "--base",
                        t,
                        "--head",
                        t,
                        "--build-directory",
                        t,
                        "--output",
                        t,
                        "--filter",
                        "flags.single.boolean",
                        "--repetitions",
                        "2",
                    ]
                ),
                0,
            )
            self.assertEqual(
                calls, ["base", "head", "base", "head", "head", "base", "head", "base"]
            )

    def test_describe_is_bounded(self):
        with tempfile.TemporaryDirectory() as t, patch.object(
            run, "worker_env", return_value={}
        ), patch.object(
            run.subprocess,
            "check_output",
            side_effect=subprocess.TimeoutExpired("ruby", run.TIMEOUT),
        ) as command:
            with self.assertRaises(subprocess.TimeoutExpired):
                run.document_for(Path(t), Path(t), "head", "pair", {}, None)
            self.assertEqual(command.call_args.kwargs["timeout"], run.TIMEOUT)

    def test_unknown_shard_and_filter_conflict(self):
        with self.assertRaises(SystemExit):
            run.main(
                [
                    "--base",
                    ".",
                    "--head",
                    ".",
                    "--build-directory",
                    ".",
                    "--output",
                    ".",
                    "--shard",
                    "unknown",
                ]
            )
        with self.assertRaises(SystemExit):
            run.main(
                [
                    "--base",
                    ".",
                    "--head",
                    ".",
                    "--build-directory",
                    ".",
                    "--output",
                    ".",
                    "--shard",
                    "capture",
                    "--filter",
                    "flags",
                ]
            )

    def test_receiver_sequence_validation(self):
        spec = next(
            s for s in fixtures.workloads(True) if s["id"] == "capture.drain.burst.32"
        )

        def request(server, path, body=None):
            req = Request(
                server.url + path,
                data=json.dumps(body).encode() if body is not None else None,
            )
            with urlopen(req, timeout=5) as response:
                return json.load(response)

        def event(i):
            return {
                "event": "benchmark",
                "distinct_id": fixtures.USERS[i % 16]["distinct_id"],
                "properties": {"sequence": i, "plan": "pro", "payload": "x" * 32},
            }

        with BenchmarkServer(spec) as server:
            request(server, "/__benchmark/reset", {"operations": 32})
            request(
                server, "/batch", {"batch": [event(i) for i in reversed(range(32))]}
            )
            state = request(server, "/__benchmark/state")
            self.assertEqual(state["missing_sequences"], 0)
            self.assertEqual(state["invalid_events"], 0)
            request(server, "/__benchmark/reset", {"operations": 32})
            # Balanced duplicate/loss preserves event/user totals but must fail.
            request(server, "/batch", {"batch": [event(i) for i in range(16)] * 2})
            state = request(server, "/__benchmark/state")
            self.assertEqual(state["delivered"], 32)
            self.assertGreater(state["missing_sequences"], 0)
            self.assertGreater(state["invalid_events"], 0)


if __name__ == "__main__":
    unittest.main()
