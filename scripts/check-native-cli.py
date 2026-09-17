#!/usr/bin/env python3
"""Read-only CLI regression: invalid/diagnostic arguments must not start capture."""
import pathlib
import subprocess
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-native-cli.py /absolute/path/to/SystemAudioProcessor")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-native-cli.py: no such path: {sys.argv[1]}")
    cases = [
        ["--intensity", "inf"],
        ["--output", "nan"],
        ["--listener-x", "NaN"],
        ["--stage-width", "-Infinity"],
        ["--spatial", "maybe"],
        ["--self-test", "--bundle-id", "com.example.not-running"],
        ["--list-apps", "--all"],
        ["--all", "--list-apps"],
        ["--self-test", "--all"],
        ["--all", "--self-test"],
        ["--ui-self-test", "--all"],
        ["--benchmark-output-conditioning", "--all"],
        ["--all", "--bundle-id", "com.example.not-running"],
    ]
    for arguments in cases:
        result = subprocess.run([str(executable), *arguments], capture_output=True, text=True, timeout=10)
        output = result.stdout + result.stderr
        if result.returncode != 1 or not output.strip() or "processing is running" in output:
            raise SystemExit(f"Invalid CLI case {arguments!r}: exit={result.returncode}, output={output!r}")
    help_result = subprocess.run([str(executable), "--help"], capture_output=True, text=True, timeout=10)
    if help_result.returncode != 0 or not all(flag in help_result.stdout for flag in
                                            ["--self-test", "--ui-self-test", "--benchmark-output-conditioning"]):
        raise SystemExit("Help command failed")
    print(f"Native CLI checks passed: {len(cases)} rejected cases and read-only help")


if __name__ == "__main__":
    main()
