"""Run native controls plus regression checks through an installed SDK and loopback receiver."""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from fixtures import workloads
from run import HERE, TIMEOUT, WORKER, run_worker, worker_env
from server import BenchmarkServer


def main(installation):
    with tempfile.TemporaryDirectory(prefix="ruby-controls-") as scratch:
        env = worker_env(installation, scratch)
        subprocess.run(
            ["ruby", str(HERE / "controls.rb")],
            env=env,
            cwd=scratch,
            check=True,
            timeout=TIMEOUT,
        )
        capture = next(
            s for s in workloads(True) if s["id"] == "capture.drain.steady.32"
        )
        code = """require ARGV[0]
PostHog::Logging.logger = Logger.new(File::NULL)
w = RubyBenchmark::Workload.new(JSON.parse(ARGV[1]), ARGV[2])
begin
  warmup = w.prepare(200)
  raise 'Warmup size changed' unless warmup == 160
  raise 'Warmup was not reset' unless w.control('state')['delivered'].zero?
  # Simulate a flush that returns without delivery at the benchmark seam, not inside the SDK.
  def w.flush; end
  w.run(200)
  begin
    w.complete
    raise 'Completed-delivery verification rescued a missing flush'
  rescue RuntimeError => error
    raise unless error.message == 'Capture payload, identity or sequence mismatch'
  end
ensure
  w.close
end
puts 'Incomplete delivery rejected without a rescuing verification flush'
"""
        with BenchmarkServer(capture) as server:
            subprocess.run(
                ["ruby", "-e", code, str(WORKER), json.dumps(capture), server.url],
                env=env,
                cwd=scratch,
                check=True,
                timeout=TIMEOUT,
            )
        refresh = next(s for s in workloads(True) if s["mode"] == "refresh")
        code = """require ARGV[0]
PostHog::Logging.logger = Logger.new(File::NULL)
w = RubyBenchmark::Workload.new(JSON.parse(ARGV[1]), ARGV[2])
begin
  w.prepare(4)
  w.reload(1)
  w.verify
  w.reload(2)
  w.verify
ensure
  w.close
end
puts 'Changing refresh generations verified for all users'
"""
        with BenchmarkServer(refresh) as server:
            subprocess.run(
                ["ruby", "-e", code, str(WORKER), json.dumps(refresh), server.url],
                env=env,
                cwd=scratch,
                check=True,
                timeout=TIMEOUT,
            )
        # Real child timeout and capped diagnostic output; no SDK state manipulation.
        sleeper = Path(scratch) / "sleeper.rb"
        sleeper.write_text("STDERR.write('x' * 100000); STDERR.flush; sleep 60\n")
        import run

        original = run.WORKER
        try:
            run.WORKER = sleeper
            raw = run_worker(installation, refresh, "memory", timeout=0.5)
            assert raw["status"] == "timeout" and 0 < len(raw["stderr"]) <= 65536
        finally:
            run.WORKER = original
        print("Real worker timeout classified with capped logs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installation", type=Path)
    main(parser.parse_args().installation.resolve())
