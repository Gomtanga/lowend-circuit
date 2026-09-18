"""Verify a cross-device route: capture one endpoint, render to a different one.

The Windows guide called this out as unverified for a while, because this
workstation had only one active output endpoint (render was ACTIVE 1, the rest
NOTPRESENT/UNPLUGGED/DISABLED) and a second one is exactly what the combination
needs. When more than one output became available, the route opened cleanly, so
the check is now a script rather than a note.

Two things are verified together, because a cross-device route is where both are
actually exercised:

  1. The render stream carries the CAPTURE device's rate, not the render
     endpoint's mix rate. With a 48 kHz capture device and a 192 kHz endpoint the
     render stream must still be 48 kHz - the audio engine performs that
     conversion (AUTOCONVERTPCM), and the engine deliberately carries no
     resampler of its own. Reporting the mix rate would mean the DSP was prepared
     at a rate its samples are not at.
  2. The two endpoints really are different, so this is not the same-device case
     the engine refuses.

Skips - reporting that it skipped, not passing - when fewer than two output
endpoints exist, which is the state that made this unverifiable before.

Usage:  python scripts/check-windows-cross-device.py /path/to/lowend_windows.exe
"""
import pathlib
import re
import signal
import subprocess
import sys
import time


def list_outputs(executable: pathlib.Path):
    """Parse --list-devices for output endpoints, in the order the CLI prints."""
    result = subprocess.run([str(executable), "--list-devices"],
                            capture_output=True, text=True, timeout=60)
    outputs = []
    in_outputs = False
    for line in result.stdout.splitlines():
        if line.startswith("Output devices"):
            in_outputs = True
            continue
        if line.startswith("Input devices"):
            in_outputs = False
            continue
        if not in_outputs:
            continue
        match = re.search(r"id=(\{[^}]*\}\.\{[^}]*\})", line)
        if match:
            rate = re.search(r"(\d+) Hz", line)
            outputs.append((match.group(1), int(rate.group(1)) if rate else 0, line.strip()))
    return outputs


def run(executable: pathlib.Path, args, seconds: int):
    process = subprocess.Popen([str(executable), *args], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True,
                               creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
    time.sleep(seconds)
    if process.poll() is None:
        try:
            process.send_signal(signal.CTRL_BREAK_EVENT)
        except Exception:
            process.terminate()
    try:
        out, err = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        out, err = process.communicate()
    return out, err, process.returncode


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-cross-device.py /path/to/lowend_windows.exe")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-cross-device.py: no such executable: {sys.argv[1]}\n"
                         "build it first: scripts\\build-windows-cli.bat Release")

    outputs = list_outputs(executable)
    if len(outputs) < 2:
        print(f"SKIPPED: this machine exposes {len(outputs)} output endpoint(s); a "
              f"cross-device route needs at least two. The route was not exercised. "
              f"This is not a pass.")
        return

    # Pick two with different mix rates when possible: that is what makes the
    # stream-rate assertion meaningful rather than trivially satisfied.
    capture = outputs[0]
    render = next((o for o in outputs[1:] if o[1] and o[1] != capture[1]), outputs[1])
    print(f"capture: {capture[2][:70]}")
    print(f"render:  {render[2][:70]}")

    out, err, rc = run(executable,
                       ["--capture-device", capture[0], "--device", render[0], "--verbose"],
                       seconds=6)

    route = next((l for l in out.splitlines() if l.startswith("capture:")), "")
    if rc != 0 or not route:
        print(f"the cross-device route did not open (exit {rc})")
        for line in (out + err).strip().splitlines()[-4:]:
            print("   ", line[:150])
        raise SystemExit("A cross-device route failed to open.")

    capture_rate = re.search(r"@ (\d+) Hz", route)
    render_rate = re.search(r"render:.*?@ (\d+) Hz", route)
    if not capture_rate or not render_rate:
        raise SystemExit(f"The route line does not report both rates:\n{route}")

    problems = []
    if capture_rate.group(1) != render_rate.group(1):
        problems.append(
            f"the render stream opened at {render_rate.group(1)} Hz while the capture "
            f"device runs at {capture_rate.group(1)} Hz; the engine would then feed the "
            f"DSP's output into a stream expecting a different rate")
    if capture[0] not in route or render[0] not in route:
        problems.append("the negotiated route does not name the two requested endpoints")

    errors = dict(re.findall(r"^\s*(Capture errors|Render errors|Dropped samples)\s+(\d+)",
                             out, re.M))
    for name in ("Capture errors", "Render errors", "Dropped samples"):
        if errors.get(name) not in ("0", None):
            problems.append(f"{name} was {errors[name]}, expected 0")

    if problems:
        for problem in problems:
            print(f"  MISMATCH: {problem}", file=sys.stderr)
        raise SystemExit("The cross-device route did not behave as documented.")

    print(f"cross-device route verified: capture at {capture_rate.group(1)} Hz on one "
          f"endpoint, render stream at {render_rate.group(1)} Hz on a different one, "
          f"0 capture/render errors and 0 dropped samples")


if __name__ == "__main__":
    main()
