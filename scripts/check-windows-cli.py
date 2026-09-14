#!/usr/bin/env python3
"""Read-only Windows CLI regression: invalid arguments must be rejected without
starting audio, and diagnostic commands must not open a device.

This checks the process boundary, which the in-process --self-test cannot:
exit codes, stderr/stdout separation, and that a rejected invocation never
prints a "running" banner.
"""
import pathlib
import subprocess
import sys


def run(executable: pathlib.Path, arguments: list) -> subprocess.CompletedProcess:
    return subprocess.run([str(executable), *arguments], capture_output=True,
                          text=True, timeout=30)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-cli.py /path/to/lowend_windows.exe")
    executable = pathlib.Path(sys.argv[1]).resolve(strict=True)

    rejected = [
        ["--intensity", "inf"],
        ["--output", "nan"],
        ["--listener-x", "NaN"],
        ["--stage-width", "-Infinity"],
        ["--spatial", "maybe"],
        ["--model", "bass"],
        ["--exciter-os", "3x"],
        ["--intensity", "55abc"],
        ["--body"],
        ["--unknown-flag"],
        ["--self-test", "--device", "x"],
        ["--list-devices", "--model", "circuit"],
        ["--self-test", "--list-devices"],
        ["--dump-settings", "--verbose"],
        ["--monitor", "0"],
        ["--monitor", "9999"],
        ["--monitor", "abc"],
        ["--monitor"],
        # Device selection: an empty or malformed id must be refused outright
        # rather than quietly falling back to the default endpoint. A silent
        # fallback would hide a typo in a saved id and process the wrong route.
        ["--device", ""],
        ["--device"],
        ["--input-device", ""],
        ["--capture-device", ""],
        ["--loopback", "sometimes"],
    ]
    # Cases where the exit code alone would not prove the right reason. A
    # contradiction between --input-device and --loopback on must be reported as
    # that contradiction: with an endpoint id that does not exist, the run would
    # also exit 1 for an unrelated device error, so asserting only the exit code
    # would pass even if the combination were no longer detected at all.
    #
    # The message for each option is the one the macOS CLI prints, because the
    # two are documented as using identical option names and error messages. A
    # missing value and an unparseable one share a message there - each option
    # checks both in one guard - so both cases are listed for the same option.
    macos_message = [
        ("--intensity", "needs a number"),
        ("--body", "needs a number"),
        ("--output", "needs a number"),
        ("--listener-x", "needs a number"),
        ("--listener-z", "needs a number"),
        ("--stage-width", "needs a number"),
        ("--space", "needs a number"),
        ("--model", "needs clean, circuit, or highexciter"),
        ("--exciter-os", "needs auto, 1x, 2x, or 4x"),
        ("--spatial", "needs on or off"),
    ]
    rejected_with_reason = [
        (["--input-device", "{0.0.1.00000000}.{00000000-0000-0000-0000-000000000000}",
          "--loopback", "on"], "cannot be combined"),
        (["--loopback", "on", "--input-device",
          "{0.0.1.00000000}.{00000000-0000-0000-0000-000000000000}"], "cannot be combined"),
        (["--device", ""], "needs a device id"),
        (["--input-device", ""], "needs a device id"),
        (["--capture-device", ""], "needs a device id"),
    ]
    # Missing value and invalid value, for every option macOS also accepts.
    for option, message in macos_message:
        rejected_with_reason.append(([option], message))
        rejected_with_reason.append(([option, "not-a-valid-value"], message))

    for arguments in rejected:
        result = run(executable, arguments)
        output = result.stdout + result.stderr
        if result.returncode != 1:
            raise SystemExit(
                f"Rejected case {arguments!r}: exit={result.returncode}, expected 1")
        if not output.strip():
            raise SystemExit(f"Rejected case {arguments!r}: produced no diagnostic output")
        if "processing is running" in output:
            raise SystemExit(f"Rejected case {arguments!r}: started audio processing")

    for arguments, reason in rejected_with_reason:
        result = run(executable, arguments)
        output = result.stdout + result.stderr
        if result.returncode != 1:
            raise SystemExit(
                f"Rejected case {arguments!r}: exit={result.returncode}, expected 1")
        if reason not in output:
            raise SystemExit(
                f"Rejected case {arguments!r}: expected the reason to mention "
                f"{reason!r}, but the output was:\n{output}")
        if "processing is running" in output:
            raise SystemExit(f"Rejected case {arguments!r}: started audio processing")

    help_result = run(executable, ["--help"])
    if help_result.returncode != 0:
        raise SystemExit(f"--help exit={help_result.returncode}, expected 0")
    for flag in ("--list-devices", "--self-test", "--dump-settings", "--model",
                 "--exciter-os", "--buffer-ms", "--monitor"):
        if flag not in help_result.stdout:
            raise SystemExit(f"--help does not document {flag}")

    # --dump-settings is device-free: it must succeed and print DSP planning.
    dump_result = run(executable, ["--dump-settings"])
    if dump_result.returncode != 0:
        raise SystemExit(f"--dump-settings exit={dump_result.returncode}, expected 0")
    if "DSP plan per sample rate" not in dump_result.stdout:
        raise SystemExit("--dump-settings did not print the DSP plan")
    if "exciter" not in dump_result.stdout:
        raise SystemExit("--dump-settings did not print the oversampling column")

    # --self-test is device-free and must report success.
    self_test = run(executable, ["--self-test"])
    if self_test.returncode != 0:
        raise SystemExit(
            f"--self-test exit={self_test.returncode}\n{self_test.stdout}\n{self_test.stderr}")
    if "All offline checks passed." not in self_test.stdout:
        raise SystemExit("--self-test did not report a passing run")

    print(f"Windows CLI checks passed: {len(rejected)} rejected cases, "
          f"{len(rejected_with_reason)} rejections verified by reason, "
          f"help, device-free --dump-settings, and --self-test")


if __name__ == "__main__":
    main()
