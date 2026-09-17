"""Long-run stability and stop/restart checks for a named capture/render pair.

The milestone needs two measurements that no offline check can stand in for: a
continuous run long enough to show a buffer trend, and repeated stop/restart
cycles. Both were first taken with a throwaway harness; this script makes them
reproducible, and takes the endpoints explicitly - never "the first output" or the
OS default, because the route being measured is defined by the ids the user names.

The capture source often delivers silence (a virtual input, a cable nothing is
playing into), which is deliberate: this measures the engine's steadiness on a
route, not whether audio is interesting. Nothing here plays a tone, changes a
volume, or touches Windows' default output.

Fixed pass/fail criteria, decided before any run:

  device errors   any capture or render error reported at stop is a failure.
  drops           any dropped sample is a failure: it means the DSP side could not
                  keep up with the capture side for the whole run.
  stalls          frames must advance monotonically and track the wall clock
                  within 1% over a run of at least 60 s; a run that stops producing
                  frames while the process lives is a failure. Shorter cycles are
                  not judged on drift, because opening the endpoint and priming the
                  ring is a measurable part of a few-second run.
  underrun        the counter is expected to settle once during priming (the ring
                  starts empty). After the priming window it must not grow by more
                  than two render periods in total - growth past that is the
                  capture side falling behind, not a startup transient.
  coverage        the samples must span the run that was asked for. A capture that
                  stops early would otherwise let a half-hour run pass on the first
                  minute it happened to see.
  cycles          every stop/restart cycle must open the route (exit 0, the
                  running banner, at least one processed frame) and report no
                  device errors or drops.

Reported but not judged: the ring-buffer trend. A steady rise is a clock
difference between two independent devices as much as it is a defect, so the
numbers (first/last quarter means, fitted slope) are printed for the report to
interpret rather than turned into a pass/fail here. A run whose buffer *stays* at
zero after priming is called out: a single reading of zero is the render side
consuming what the capture side just wrote (equilibrium, and the porting branch's
own records show it), while a tenth of the settled samples reading zero is
starvation.

Usage:
  python scripts/check-windows-route-stability.py <exe> --capture <id> --render <id> \
      [--minutes N] [--cycles N] [--cycle-seconds S]

Both --minutes and --cycles may be given; cycles run first. Missing the endpoints
is a usage error, not a skip: nothing is measured without them.
"""
import argparse
import pathlib
import re
import signal
import statistics
import subprocess
import sys
import threading
import time

PRIMING_SECONDS = 10.0
UNDERRUN_GROWTH_LIMIT_SAMPLES = 4096   # ~43 ms at 48 kHz stereo
DRIFT_LIMIT_RATIO = 0.01               # frames vs wall clock
SAMPLE_RE = re.compile(r"^(\d+\.\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)$")


def start(executable: pathlib.Path, args):
    process = subprocess.Popen([str(executable), *args], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True,
                               creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
    # The run's statistics are only useful if the pipe is read while it runs. Sleeping
    # first and collecting at the end looks equivalent but is not: the engine's stats
    # fill the ~64 KiB pipe buffer after roughly a minute and a half, and everything
    # after that is lost, so a half-hour run gets judged on its first minute.
    process.captured = []
    process.reader = threading.Thread(target=drain, args=(process,), daemon=True)
    process.reader.start()
    return process


def drain(process):
    for line in process.stdout:
        process.captured.append(line)


def stop(process, seconds: float = 0.0):
    if process is None:
        return ""
    if seconds:
        time.sleep(seconds)
    if process.poll() is None:
        try:
            process.send_signal(signal.CTRL_BREAK_EVENT)
        except Exception:
            process.terminate()
    try:
        process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    process.reader.join(timeout=10)
    try:
        process.stdout.close()
    except Exception:
        pass
    return "".join(process.captured)


def counter(text: str, label: str):
    match = re.search(rf"^{label}\s+(\d+)", text, re.M)
    return int(match.group(1)) if match else None


def buffer_frames(text: str):
    match = re.search(r"(\d+) frames, [\d.]+ ms buffer", text)
    return int(match.group(1)) if match else 0


def samples(text: str):
    out = []
    for line in text.splitlines():
        match = SAMPLE_RE.match(line.strip())
        if match:
            out.append({
                "elapsed": float(match.group(1)),
                "frames": int(match.group(2)),
                "dropped": int(match.group(3)),
                "underrun": int(match.group(4)),
                "recovered": int(match.group(5)),
                "buffered": int(match.group(6)),
            })
    return out


def judge_run(label, text, exit_code, observed, problems, expected_seconds=None):
    """Applies the fixed criteria to one continuous run."""
    if exit_code != 0:
        problems.append(f"{label}: the engine exited with code {exit_code}")
    if not observed:
        problems.append(f"{label}: no statistics were reported, so nothing was observed")
        return
    # A run is judged on the samples it produced, so the samples have to cover the run
    # that was asked for. Without this the criteria below pass on any prefix of the run
    # (a truncated capture of a 30-minute run looks like a healthy 90-second one).
    if expected_seconds and observed[-1]["elapsed"] < expected_seconds - 5.0:
        problems.append(
            f"{label}: only {observed[-1]['elapsed']:.1f} s of statistics were captured "
            f"for a {expected_seconds:.0f} s run")
    if counter(text, "Capture errors") or counter(text, "Render errors"):
        problems.append(f"{label}: device errors were reported at stop")
    dropped = counter(text, "Dropped samples")
    if dropped:
        problems.append(f"{label}: {dropped} dropped samples")
    last = observed[-1]
    if last["frames"] <= 0:
        problems.append(f"{label}: no frames were processed")
    if any(b["frames"] < a["frames"] for a, b in zip(observed, observed[1:])):
        problems.append(f"{label}: the frame counter went backwards, so the stream stalled")

    rate_match = re.search(r"@ (\d+) Hz", text)
    rate = int(rate_match.group(1)) if rate_match else 48000
    # Only long runs are judged on drift: a few-second cycle spends a measurable
    # fraction of its time opening the endpoint and priming the ring, so its
    # frames/rate ratio is short by the startup cost rather than out of step. The
    # criterion exists to catch a stream that stops advancing, which is a
    # continuous-run question.
    if last["elapsed"] >= 60.0:
        drift = abs(last["frames"] / rate - last["elapsed"]) / last["elapsed"]
        if drift > DRIFT_LIMIT_RATIO:
            problems.append(f"{label}: frames drifted {drift * 100:.2f}% from the wall clock")

    settled = [s for s in observed if s["elapsed"] >= PRIMING_SECONDS]
    if settled:
        growth = max(s["underrun"] for s in settled) - min(s["underrun"] for s in settled)
        if growth > UNDERRUN_GROWTH_LIMIT_SAMPLES:
            problems.append(
                f"{label}: underrun grew by {growth} samples after priming "
                f"(limit {UNDERRUN_GROWTH_LIMIT_SAMPLES})")
        # An instantaneous reading of zero is equilibrium, not starvation: the render
        # side consumes as the capture side fills, and the engine's own counter has
        # already said whether a render period was missed. Persistence is the signal,
        # so a tenth of the settled samples reading zero is called out.
        zeros = sum(1 for s in settled if s["buffered"] == 0)
        if zeros > len(settled) // 10:
            problems.append(
                f"{label}: the ring buffer read zero in {zeros} of {len(settled)} "
                f"samples after priming (starvation)")

    print(f"  {label}: frames={last['frames']} dropped={counter(text, 'Dropped samples')} "
          f"underrun={counter(text, 'Underrun samples')} resyncs={counter(text, 'Resyncs')} "
          f"errors={counter(text, 'Capture errors')}/{counter(text, 'Render errors')}")


def report_trend(label, observed):
    settled = [s for s in observed if s["elapsed"] >= PRIMING_SECONDS]
    if len(settled) < 8:
        print(f"  {label}: too few samples for a buffer trend")
        return
    values = [s["buffered"] for s in settled]
    quarter = max(1, len(values) // 4)
    times = [s["elapsed"] for s in settled]
    mean_t = statistics.fmean(times)
    mean_v = statistics.fmean(values)
    denominator = sum((t - mean_t) ** 2 for t in times) or 1.0
    slope = sum((t - mean_t) * (v - mean_v) for t, v in zip(times, values)) / denominator
    print(f"  {label}: buffer {min(values)}..{max(values)} samples, "
          f"first-quarter mean {statistics.fmean(values[:quarter]):.0f}, "
          f"last-quarter mean {statistics.fmean(values[-quarter:]):.0f}, "
          f"slope {slope:.2f}/s over {settled[-1]['elapsed']:.0f} s")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("executable")
    parser.add_argument("--capture", required=True, help="capture endpoint id (input or loopback)")
    parser.add_argument("--render", required=True, help="render endpoint id")
    parser.add_argument("--capture-mode", choices=("input", "loopback"), default="input",
                        help="how to open the capture endpoint: 'input' records a real input "
                             "endpoint (--input-device), 'loopback' captures an output endpoint's "
                             "own audio (--capture-device with --loopback on). Default: input, "
                             "which is the milestone route's shape. The mode is a flag rather than "
                             "something inferred from the id, because endpoint ids are opaque.")
    parser.add_argument("--minutes", type=float, default=0.0,
                        help="continuous run length; 0 skips the continuous half")
    parser.add_argument("--cycles", type=int, default=0, help="stop/restart cycles; 0 skips")
    parser.add_argument("--cycle-seconds", type=float, default=8.0)
    args = parser.parse_args()

    try:
        executable = pathlib.Path(args.executable).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-route-stability.py: no such executable: {args.executable}\n"
                         "build it first: scripts\\build-windows-cli.bat Release")
    if args.capture == args.render:
        raise SystemExit("--capture and --render are the same endpoint; that route is refused")
    if args.minutes <= 0 and args.cycles <= 0:
        parser.error("give --minutes, --cycles, or both")

    problems = []
    if args.capture_mode == "loopback":
        engine_args = ["--capture-device", args.capture, "--loopback", "on",
                       "--device", args.render, "--model", "circuit", "--verbose"]
    else:
        engine_args = ["--input-device", args.capture,
                       "--device", args.render, "--model", "circuit", "--verbose"]

    if args.cycles:
        print(f"stop/restart: {args.cycles} cycle(s), {args.cycle_seconds:.1f} s each")
        for index in range(1, args.cycles + 1):
            process = start(executable, engine_args)
            text = stop(process, args.cycle_seconds)
            observed = samples(text)
            opened = "running" in text and "Failed to start" not in text
            if not opened:
                problems.append(f"cycle {index}: the route did not open")
            judge_run(f"cycle {index}", text, process.returncode, observed, problems,
                      args.cycle_seconds)

    if args.minutes > 0:
        print(f"continuous run: {args.minutes:.1f} minute(s)")
        process = start(executable, engine_args)
        text = stop(process, args.minutes * 60.0)
        observed = samples(text)
        judge_run("continuous", text, process.returncode, observed, problems,
                  args.minutes * 60.0)
        report_trend("continuous", observed)

    if problems:
        for problem in problems:
            print(f"  PROBLEM: {problem}", file=sys.stderr)
        return 1
    print("route stability checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
