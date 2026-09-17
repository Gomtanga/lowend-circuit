"""Verify processed audio actually lands on the render device.

Every other check stops at "the render stream opened and accepted writes". That
is not the same as "audio reached the endpoint": a stream can open, accept
blocks, and still deliver nothing audible if the format or the route is wrong.
The only way to see the result is to observe the render endpoint's OWN loopback,
which shows exactly what is being played to it.

Two measurements make that rigorous:

  1. A baseline with nothing rendering to the endpoint. A WASAPI loopback of an
     idle output produces no packets at all, so an empty baseline is a clean
     control rather than a noisy one.
  2. An A/B comparison of two runs against that endpoint, identical except for
     the DSP model. `clean` with intensity and body at 0 is the documented
     bit-exact bypass, while Circuit applies a low shelf and saturation and lands
     measurably lower. Comparing the levels a tone produces at the destination
     therefore shows whether the engine's DSP shaped the audio on its way there -
     and because both runs use the same tone, the same endpoints and the same
     session volume, the comparison does not depend on how loud the system is.

Skips - reporting that it skipped, not passing - when fewer than two output
endpoints exist, or when the tone cannot be observed reaching the destination.

Usage:  python scripts/check-windows-render-landing.py /path/to/lowend_windows.exe
"""
import math
import pathlib
import re
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave

TONE_HZ = 440.0
TONE_AMPLITUDE = 0.4
TONE_RATE = 48000
MONITOR_SECONDS = 5
# The endpoint is silent when nothing renders to it, so any real signal clears
# this by an order of magnitude.
SIGNAL_PEAK_MIN = 0.02
# Circuit with the defaults lands around 0.65x of the dry level. The bound is
# loose on purpose: this asserts "the DSP shaped it", not an exact gain, because
# the shelf is signal dependent.
CIRCUIT_ATTENUATION_MAX = 0.90


def list_outputs(executable: pathlib.Path):
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
        if in_outputs:
            match = re.search(r"id=(\{[^}]*\}\.\{[^}]*\})", line)
            if match:
                outputs.append((match.group(1), line.strip()))
    return outputs


def make_tone(path: pathlib.Path, seconds: int) -> None:
    frames = bytearray()
    for i in range(TONE_RATE * seconds):
        value = int(TONE_AMPLITUDE * 32767 *
                    math.sin(2.0 * math.pi * TONE_HZ * i / TONE_RATE))
        frames += struct.pack("<hh", value, value)
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(TONE_RATE)
        handle.writeframes(bytes(frames))


def start(executable: pathlib.Path, args):
    return subprocess.Popen([str(executable), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True,
                            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))


def stop(process, seconds: float = 0.0):
    if seconds:
        time.sleep(seconds)
    if process.poll() is None:
        try:
            process.send_signal(signal.CTRL_BREAK_EVENT)
        except Exception:
            process.terminate()
    try:
        return process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.communicate()


def measure(executable: pathlib.Path, device: str):
    """Monitor one endpoint's own loopback and return (peak, packets, frames, output)."""
    out, err = stop(start(executable, ["--monitor", str(MONITOR_SECONDS),
                                       "--capture-device", device]), MONITOR_SECONDS + 1.5)
    text = out + err
    peak = re.search(r"input peak:\s+([0-9.]+)", text)
    packets = re.search(r"packets:\s+(\d+)", text)
    frames = re.search(r"frames:\s+(\d+)", text)
    return (float(peak.group(1)) if peak else None,
            int(packets.group(1)) if packets else None,
            int(frames.group(1)) if frames else None,
            text)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-render-landing.py /path/to/lowend_windows.exe")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-render-landing.py: no such executable: {sys.argv[1]}\n"
                         "build it first: scripts\\build-windows-cli.bat Release")

    try:
        import winsound
    except ImportError:
        print("SKIPPED: this check needs Windows (winsound) to play the tone. "
              "The landing behaviour was not observed. This is not a pass.")
        return

    outputs = list_outputs(executable)
    if len(outputs) < 2:
        print(f"SKIPPED: this machine exposes {len(outputs)} output endpoint(s); "
              f"observing a render destination needs a second one. The landing "
              f"behaviour was not observed. This is not a pass.")
        return

    # The tone plays on the default endpoint, so that one is the capture side and
    # the next one is the destination whose loopback is observed.
    source, destination = outputs[0], outputs[1]
    print(f"source:      {source[1][:70]}")
    print(f"destination: {destination[1][:70]}")

    with tempfile.TemporaryDirectory() as scratch:
        tone = pathlib.Path(scratch) / "landing-tone.wav"
        make_tone(tone, seconds=16)

        # 1. Baseline: nothing is rendering to the destination.
        base_peak, base_packets, base_frames, _ = measure(executable, destination[0])
        print(f"baseline (nothing rendering): packets={base_packets} frames={base_frames}")

        def landed(args, label):
            play = threading.Thread(target=winsound.PlaySound,
                                    args=(str(tone), winsound.SND_FILENAME))
            play.start()
            time.sleep(0.6)
            engine = start(executable, ["--capture-device", source[0],
                                        "--device", destination[0], *args])
            time.sleep(2.5)
            try:
                peak, packets, frames, _ = measure(executable, destination[0])
            finally:
                engine_out, engine_err = stop(engine)
                play.join(timeout=20)
            errors = dict(re.findall(r"^\s*(Capture errors|Render errors)\s+(\d+)",
                                     engine_out + engine_err, re.M))
            print(f"{label}: packets={packets} frames={frames} peak={peak} "
                  f"engine errors={errors}")
            return peak, packets, frames, engine_out + engine_err

        # 2. The DSP in the path, then the documented bypass, so the levels can be
        #    compared against the same destination in the same session.
        circuit_peak, circuit_packets, circuit_frames, _ = landed([], "circuit (default)")
        clean_peak, clean_packets, clean_frames, _ = landed(
            ["--model", "clean", "--intensity", "0", "--body", "0", "--output", "0"],
            "clean bypass")

    if not circuit_peak or not clean_peak:
        # A run that produced no peak at all is reported as zero when the
        # endpoint delivered packets, which is the signature of a stream that
        # opened and accepted writes but carried silence.
        raise SystemExit(
            f"A run reported no peak at the destination (circuit={circuit_peak}, "
            f"clean={clean_peak}); a render stream that delivers packets with no level "
            f"is carrying silence, so the processed audio is not reaching the endpoint.")

    problems = []
    # The destination was idle, so packets arriving at all means the engine's
    # render stream reached it.
    if not base_packets:
        if not circuit_packets:
            problems.append(
                "the destination delivered no packets while the engine rendered to it; "
                "the processed audio never reached the endpoint")
    elif base_peak is not None and circuit_peak <= base_peak:
        problems.append(
            f"the destination's level ({circuit_peak:.6f}) did not rise above its idle "
            f"level ({base_peak:.6f})")

    if circuit_peak < SIGNAL_PEAK_MIN:
        problems.append(
            f"the destination only reached peak {circuit_peak:.6f}; the processed audio "
            f"is not arriving at a usable level")
    if not circuit_frames or circuit_frames < TONE_RATE * (MONITOR_SECONDS - 2):
        problems.append(
            f"the destination delivered only {circuit_frames} frames for a "
            f"{MONITOR_SECONDS}s window")

    # The decisive one: identical tone, identical endpoints, only the model
    # differs. A bypass that does not change the level while Circuit lowers it
    # means the engine's DSP is what shaped the audio on the way to the endpoint.
    if not clean_peak > circuit_peak:
        problems.append(
            f"the bypass run landed at {clean_peak:.6f} and the Circuit run at "
            f"{circuit_peak:.6f}; the DSP model made no difference to what reached the "
            f"endpoint, so the engine's processing may not be in the path")
    elif clean_peak > 0 and circuit_peak / clean_peak >= CIRCUIT_ATTENUATION_MAX:
        problems.append(
            f"the Circuit run landed at {circuit_peak / clean_peak:.2f}x of the bypass "
            f"run, above the {CIRCUIT_ATTENUATION_MAX:.2f}x bound; the DSP did not apply "
            f"its documented attenuation")

    if problems:
        for problem in problems:
            print(f"  MISMATCH: {problem}", file=sys.stderr)
        raise SystemExit("Processed audio did not verifiably land on the render device.")

    print(f"\nrender landing verified: the destination endpoint was idle "
          f"({base_packets} packets), and the engine's output arrived on it "
          f"({circuit_frames} frames at peak {circuit_peak:.6f}). The same tone through "
          f"the documented bypass landed at {clean_peak:.6f}, so the DSP is in the path "
          f"({circuit_peak / clean_peak:.2f}x).")


if __name__ == "__main__":
    main()
