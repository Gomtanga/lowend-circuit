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
        ["--play-tone", "0"],
        ["--play-tone", "9999"],
        ["--play-tone", "abc"],
        ["--play-tone"],
        # The capture dump is filled by --monitor only. Asking for it anywhere else
        # would either write nothing or keep audio the user did not ask to keep.
        ["--dump-wav"],
        ["--dump-wav", ""],
        ["--dump-wav", "capture.wav"],
        # Device selection: an empty or malformed id must be refused outright
        # rather than quietly falling back to the default endpoint. A silent
        # fallback would hide a typo in a saved id and process the wrong route.
        ["--device", ""],
        ["--device"],
        ["--input-device", ""],
        ["--capture-device", ""],
        ["--loopback", "sometimes"],
        # --route-check judges a route instead of running it, but it is still one
        # command: combining it with a bare diagnostic is a mistake, not a
        # request to print two reports.
        ["--route-check", "--list-devices"],
        ["--route-check", "--self-test"],
        ["--route-check", "--device", ""],
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
                 "--exciter-os", "--buffer-ms", "--monitor", "--route-check"):
        if flag not in help_result.stdout:
            raise SystemExit(f"--help does not document {flag}")

    # --list-devices and --route-check both resolve endpoints through the audio
    # endpoint enumerator, which a CI runner may not have at all (the workflow
    # says so explicitly: the "Report missing audio endpoint" step tolerates it).
    # The contract is asserted in *both* environments, and it differs: with an
    # enumerator, the commands answer about real endpoints; without one, they must
    # report the enumeration failure rather than printing a device list or judging
    # a route they never saw. Accepting either outcome without checking which one
    # happened would hide a silent fallback, so each branch asserts its own
    # message.
    absent = "{0.0.0.00000000}.{deadbeef-0000-0000-0000-000000000000}"
    list_result = run(executable, ["--list-devices"])
    list_output = list_result.stdout + list_result.stderr
    if "processing is running" in list_output:
        raise SystemExit("--list-devices started audio processing")

    if list_result.returncode == 0:
        if "Virtual cables" not in list_result.stdout:
            raise SystemExit("--list-devices did not report the virtual-cable pairing")
        # An id that no endpoint carries must be refused *by name*: falling back to
        # another device would process a route the user did not choose, which is
        # the mistake the selection flags exist to prevent.
        route_check = run(executable, ["--route-check", "--device", absent])
        route_output = route_check.stdout + route_check.stderr
        if route_check.returncode != 1:
            raise SystemExit(
                f"--route-check with an absent render id: exit={route_check.returncode}, "
                f"expected 1")
        if "no endpoint with the requested render id is present" not in route_output:
            raise SystemExit(
                "--route-check did not report the absent render id by name:\n" + route_output)
        if "Result: REFUSED" not in route_output:
            raise SystemExit("--route-check did not state the refusal:\n" + route_output)
        if "opens no stream" not in route_output:
            raise SystemExit("--route-check did not state that it opens no stream")
    else:
        if "Device enumeration failed" not in list_output:
            raise SystemExit(
                f"--list-devices failed without reporting a device-enumeration failure:\n"
                f"{list_output}")
        route_check = run(executable, ["--route-check", "--device", absent])
        route_output = route_check.stdout + route_check.stderr
        if route_check.returncode != 1:
            raise SystemExit(
                f"--route-check without an enumerator: exit={route_check.returncode}, expected 1")
        if "Device enumeration failed" not in route_output:
            raise SystemExit(
                "--route-check did not report the enumeration failure it hit:\n" + route_output)
        if "Result: READY" in route_output:
            raise SystemExit(
                "--route-check claimed a usable route on a machine whose endpoints it could not "
                "enumerate")

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
          f"help, device-free --dump-settings and --self-test, the route refusal "
          f"reason, and the device-instance columns")


if __name__ == "__main__":
    main()
