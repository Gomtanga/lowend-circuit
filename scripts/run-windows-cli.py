"""Run the Windows CLI for a bounded time, then stop it and report the run stats.

Used as a local verification step: the engine is a live process, so a run has to
be started, given time to move real audio, then interrupted. Prints the summary
counters the CLI reports on shutdown.

Usage:  python scripts/run-windows-cli.py <exe> <seconds> [args...]
"""
import re
import signal
import subprocess
import sys
import time

COUNTERS = ("Capture errors", "Render errors", "Resyncs", "Dropped samples",
            "Underrun samples", "Processed frames")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("Usage: run-windows-cli.py <exe> <seconds> [args...]")
    executable, seconds = sys.argv[1], float(sys.argv[2])
    arguments = sys.argv[3:]

    creation = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    process = subprocess.Popen([executable, *arguments], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, creationflags=creation)
    started = time.monotonic()
    time.sleep(seconds)

    # CTRL_BREAK reaches the handler the CLI installs; terminate() would skip the
    # shutdown path and hide the statistics this script exists to report.
    if creation:
        process.send_signal(signal.CTRL_BREAK_EVENT)
    else:
        process.terminate()

    try:
        out, err = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        out, err = process.communicate()
        raise SystemExit("The engine did not stop within 30 s of the stop request.")

    elapsed = time.monotonic() - started
    route = [line for line in out.splitlines() if line.startswith("capture:")]
    print("elapsed: %.1f s" % elapsed)
    if route:
        print(route[0])

    stats = dict(re.findall(r"^(%s)\s+(\d+)" % "|".join(COUNTERS), out, re.M))
    for name in COUNTERS:
        print("  %-16s %s" % (name, stats.get(name, "?")))

    frames = int(stats.get("Processed frames", 0))
    underrun_samples = int(stats.get("Underrun samples", 0))
    rate = 48000
    if route:
        match = re.search(r"@ (\d+) Hz", route[0])
        if match:
            rate = int(match.group(1))
    print("  frames -> %.2f s of audio at %d Hz" % (frames / rate, rate))
    print("  underrun -> %.2f ms" % (underrun_samples / 2 / rate * 1000.0))
    print("exit: %d" % process.returncode)
    if err.strip():
        print("stderr:\n%s" % err.strip())

    sys.exit(process.returncode if process.returncode != 0 else 0)


if __name__ == "__main__":
    main()
