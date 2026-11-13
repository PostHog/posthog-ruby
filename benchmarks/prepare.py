"""Build and install each SDK gem separately; workers never load a checkout."""

import argparse
import json
import os
import subprocess
from pathlib import Path


def prepare(directory, output):
    directory, output = directory.resolve(), output.resolve()
    # An old installed gem with the same version must not mask a new build.
    output.mkdir(parents=True, exist_ok=False)
    env = {
        **os.environ,
        "BUNDLE_GEMFILE": str(directory / "Gemfile"),
        "BUNDLE_FROZEN": "true",
    }
    subprocess.run(
        ["bundle", "install"],
        cwd=directory,
        env=env,
        check=True,
        timeout=120,
    )
    dependency = json.loads(
        subprocess.check_output(
            [
                "bundle",
                "exec",
                "ruby",
                "-rjson",
                "-rconcurrent",
                "-e",
                'puts JSON.generate({version: Concurrent::VERSION, gem_path: Gem.loaded_specs.fetch("concurrent-ruby").base_dir})',
            ],
            cwd=directory,
            env=env,
            text=True,
            timeout=120,
        )
    )
    artifact = output / "sdk.gem"
    subprocess.run(
        ["gem", "build", "posthog-ruby.gemspec", "--output", str(artifact)],
        cwd=directory,
        check=True,
        timeout=120,
    )
    gems = output / "gems"
    subprocess.run(
        [
            "gem",
            "install",
            str(artifact),
            "--local",
            "--ignore-dependencies",
            "--no-document",
            "--install-dir",
            str(gems),
        ],
        cwd=output,
        check=True,
        timeout=120,
    )
    specs = list((gems / "specifications").glob("posthog-ruby-*.gemspec"))
    if len(specs) != 1:
        raise ValueError("Expected one installed SDK gem")
    version = specs[0].stem.removeprefix("posthog-ruby-")
    info = {
        "gem_home": str(gems),
        "gem_path": dependency["gem_path"],
        "sdk_version": version,
        "concurrent_version": dependency["version"],
        "artifact": str(artifact),
    }
    (output / "installation.json").write_text(json.dumps(info, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    prepare(options.directory, options.output)
