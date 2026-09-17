#!/usr/bin/env python3
"""Verify that Windows system-audio (WASAPI loopback) capture actually delivers audio.

The recipe this automates:

  1. Play a known tone on the default output endpoint.
  2. Run the CLI's capture-only `--monitor` on that endpoint's loopback.
  3. Repeat with nothing playing.

The check passes only if the monitored signal is clearly present while the tone
plays and clearly absent while it does not. Both halves are required: a monitor
that always reports signal, or always reports silence, fails.

Scope: this verifies capture and the DSP stage over a real endpoint. It does not
open a render endpoint, so it works when the captured endpoint is the machine's
only output. It says nothing about the loopback-to-a-different-output route,
latency, Bluetooth, or listening quality.

Usage:  python scripts/check-windows-system-audio.py <path/to/lowend_windows.exe>
"""
import math
import pathlib
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave

# Windows-only modules; imported lazily so --help still works elsewhere.
try:
    import winsound
except ImportError:  # pragma: no cover - non-Windows
    winsound = None

TONE_HZ = 440.0
TONE_SECONDS = 8
TONE_AMPLITUDE = 0.4
MONITOR_SECONDS = 4
TONE_RATE = 48000
# An order of magnitude apart, so a passing run cannot come from noise or from a
# monitor that simply reports a constant.
SIGNAL_PEAK_MIN = 0.05
SILENCE_PEAK_MAX = 0.005


def make_tone(path: pathlib.Path) -> None:
    frames = bytearray()
    for i in range(TONE_RATE * TONE_SECONDS):
        value = int(TONE_AMPLITUDE * 32767 * math.sin(2.0 * math.pi * TONE_HZ * i / TONE_RATE))
        frames += struct.pack("<hh", value, value)
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(TONE_RATE)
        handle.writeframes(bytes(frames))


def monitor(executable: pathlib.Path, seconds: int) -> tuple:
    result = subprocess.run([str(executable), "--monitor", str(seconds)],
                            capture_output=True, text=True, timeout=seconds + 60)
    output = result.stdout + result.stderr
    # The peak lines report the wider channel first and then each channel:
    # "input peak:    0.294982  (L 0.294982, R 0.294982)".
    peak = re.search(r"input peak:\s+([0-9.]+)", output)
    out_peak = re.search(r"output peak:\s+([0-9.]+)", output)
    channels = re.search(r"input peak:\s+[0-9.]+\s+\(L ([0-9.]+), R ([0-9.]+)\)", output)
    packets = re.search(r"packets:\s+(\d+)", output)
    frames = re.search(r"frames:\s+(\d+)", output)
    return (result.returncode, output,
            float(peak.group(1)) if peak else None,
            int(packets.group(1)) if packets else None,
            int(frames.group(1)) if frames else None,
            float(out_peak.group(1)) if out_peak else None,
            (float(channels.group(1)), float(channels.group(2))) if channels else None)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-system-audio.py /path/to/lowend_windows.exe")
    if winsound is None:
        raise SystemExit("This check needs Windows (winsound).")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-system-audio.py: no such executable: {sys.argv[1]}\n"
                         "build it first: scripts\\build-windows-cli.bat Release")

    with tempfile.TemporaryDirectory() as scratch:
        tone = pathlib.Path(scratch) / "tone.wav"
        make_tone(tone)

        # Silence first: nothing has been played yet on this endpoint.
        #
        # A loopback capture of an idle output endpoint produces NO packets at
        # all, rather than a stream of silence: the audio engine only runs the
        # endpoint's stream while something is rendering to it. So "no packets"
        # is the expected observation here, not a failure.
        (silent_rc, silent_out, silent_peak, silent_packets, silent_frames,
         silent_out_peak, _silent_channels) = monitor(executable, MONITOR_SECONDS)
        if silent_rc != 0 and silent_packets != 0:
            raise SystemExit(f"Silent monitor failed (exit {silent_rc}):\n{silent_out}")

        # Now with the tone playing. Playback runs on its own thread; the monitor
        # is started after a short lead-in so the tone is already streaming.
        playback = threading.Thread(target=winsound.PlaySound,
                                    args=(str(tone), winsound.SND_FILENAME))
        playback.start()
        time.sleep(0.5)
        try:
            (signal_rc, signal_out, signal_peak, signal_packets, signal_frames,
             signal_out_peak, signal_channels) = monitor(executable, MONITOR_SECONDS)
        finally:
            playback.join(timeout=TONE_SECONDS + 5)
        if signal_rc != 0:
            raise SystemExit(f"Signal monitor failed (exit {signal_rc}):\n{signal_out}")

    if signal_peak is None:
        raise SystemExit("The monitor did not report an input peak; cannot judge.")

    silent_text = "no packets" if not silent_packets else f"peak={silent_peak:.6f}"
    print(f"silence: {silent_text} packets={silent_packets} frames={silent_frames}")
    print(f"tone:    peak={signal_peak:.6f} packets={signal_packets} frames={signal_frames}")

    # Silence must NOT carry signal. Either no packets at all (the idle endpoint
    # case) or packets carrying nothing satisfies that.
    if silent_packets and silent_peak is not None and silent_peak > SILENCE_PEAK_MAX:
        # Two very different causes look identical here, and the second one is
        # not a defect: with a loopback capture, anything at all playing on the
        # endpoint — a previous run of this script, the user's music, a system
        # sound — makes the "nothing playing" phase meaningless.
        detail = ""
        if signal_peak and abs(silent_peak - signal_peak) < SIGNAL_PEAK_MIN:
            detail = ("\nThe level matches the tone phase, which usually means something was"
                      " already playing on this endpoint when the silence phase ran."
                      " Close other audio sources and run this again.")
        raise SystemExit(
            f"Expected no signal with nothing playing, saw peak {silent_peak:.6f} "
            f"(limit {SILENCE_PEAK_MAX}). The monitor may be reading noise, or the"
            f" endpoint was busy.{detail}")
    if signal_peak < SIGNAL_PEAK_MIN:
        raise SystemExit(
            f"Expected the played tone, saw peak {signal_peak:.6f} "
            f"(minimum {SIGNAL_PEAK_MIN}). Loopback capture is not delivering audio.")
    if not signal_packets:
        raise SystemExit("The endpoint delivered no packets while a tone was playing.")
    # The frames actually consumed must cover the requested window; a monitor
    # that returns early would otherwise pass on a single lucky packet.
    if not signal_frames or signal_frames < TONE_RATE * (MONITOR_SECONDS - 2):
        raise SystemExit(f"Monitor consumed only {signal_frames} frames for a "
                         f"{MONITOR_SECONDS}s window.")

    print("System-audio loopback capture verified: the monitor saw the played tone "
          "and saw no signal when nothing was playing.")

    # The output figures are measured after the DSP stage, on the same captured
    # audio the input figures describe. Asserting them is what makes the claim
    # "the tone was processed by the core" verifiable rather than assumed: an
    # input-only check would pass just as well if the core were bypassed or
    # absent from the signal path entirely.
    if signal_out_peak is None:
        raise SystemExit("The monitor did not report an output peak; cannot judge the DSP stage.")
    if signal_out_peak < SIGNAL_PEAK_MIN:
        raise SystemExit(
            f"The DSP stage produced peak {signal_out_peak:.6f} (minimum {SIGNAL_PEAK_MIN}) "
            f"from an input of {signal_peak:.6f}; the core is not passing audio through.")

    # Circuit applies a low shelf and gentle saturation, so it reshapes the tone
    # rather than passing it bit-for-bit. A stage that returned its input
    # unchanged would leave the output peak exactly equal to the input peak.
    if abs(signal_out_peak - signal_peak) < 1.0e-6:
        raise SystemExit(
            f"The DSP output peak equals the input peak exactly ({signal_peak:.6f}); "
            f"the core does not appear to be altering the signal.")

    # Both channels must carry the tone. The played WAV is stereo with the same
    # signal on each side, so a channel that reads as silent means the capture or
    # the DSP dropped it - which a single combined peak cannot show.
    if signal_channels is None:
        raise SystemExit("The monitor did not report per-channel peaks; cannot judge "
                         "whether both channels carried the tone.")
    left_peak, right_peak = signal_channels
    if min(left_peak, right_peak) < SIGNAL_PEAK_MIN:
        raise SystemExit(
            f"A channel carried no signal from a stereo tone (L {left_peak:.6f}, "
            f"R {right_peak:.6f}, minimum {SIGNAL_PEAK_MIN}); the capture or the DSP "
            f"is dropping one channel.")

    print(f"DSP stage applied to captured audio: input peak {signal_peak:.6f} "
          f"(L {left_peak:.6f}, R {right_peak:.6f}) -> output peak {signal_out_peak:.6f}")


if __name__ == "__main__":
    main()
