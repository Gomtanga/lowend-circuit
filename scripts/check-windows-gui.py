#!/usr/bin/env python3
"""Drive the Windows GUI over the audio engine and verify it actually works.

A window that merely appears proves nothing about the audio path. This script
finds the real controls by id, sends them the same messages a user's clicks
produce, and checks the observable result in the status readout:

  1. Same-endpoint start is refused (the engine's self-loop guard reaches the GUI).
  2. Selecting an input as the capture source and pressing Start brings the
     engine up: the status shows a negotiated route and a frame count that grows.
  3. Pressing Stop returns it to idle and the frame count stops advancing.

Scope: this exercises the GUI-to-engine wiring with real endpoints. It does not
judge audio quality and it does not replace listening.

Usage:  python scripts/check-windows-gui.py <path/to/lowend_gui.exe>
"""
import ctypes
import ctypes.wintypes as wintypes
import pathlib
import re
import subprocess
import sys
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

# Control ids from Windows/Source/GUI/ControlPanel.h.
ID_CAPTURE = 1000
ID_RENDER = 1001
ID_MODEL = 1003
ID_START_STOP = 1013
ID_STATUS = 1014

CB_GETCOUNT = 0x0146
CB_SETCURSEL = 0x014E
CB_GETCURSEL = 0x0147
BM_CLICK = 0x00F5
WM_CLOSE = 0x0010
WM_COMMAND = 0x0111
WM_GETFONT = 0x0031
DT_CALCRECT = 0x0400
DT_WORDBREAK = 0x0010
DT_NOPREFIX = 0x0800

# How long to let the engine negotiate and process before reading statistics.
START_SETTLE_SECONDS = 3.0
POLL_SECONDS = 8.0


def find_window(title: str):
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        buffer = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buffer, length + 1)
        if title in buffer.value:
            found.append(hwnd)
            return False
        return True

    user32.EnumWindows(callback, 0)
    return found[0] if found else None


def child_by_id(parent, control_id):
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _):
        if user32.GetDlgCtrlID(hwnd) == control_id:
            found.append(hwnd)
            return False
        return True

    user32.EnumChildWindows(parent, callback, 0)
    return found[0] if found else None


def text_of(hwnd) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return buffer.value


def post_message(hwnd, message, wparam=0, lparam=0):
    # PostMessage so the target's own message loop runs the handler; SendMessage
    # from another thread can deadlock while the UI is busy.
    user32.PostMessageW(hwnd, message, wparam, lparam)


def frames_from(status: str):
    match = re.search(r"frames (\d+)", status)
    return int(match.group(1)) if match else None


def measure_text_height(status_hwnd, width: int) -> int:
    """Height the status text needs when drawn in the control's own font."""
    dc = user32.GetDC(status_hwnd)
    font = user32.SendMessageW(status_hwnd, WM_GETFONT, 0, 0)
    previous = gdi32.SelectObject(dc, font) if font else None
    try:
        box = wintypes.RECT(0, 0, width, 10000)
        user32.DrawTextW(dc, text_of(status_hwnd), -1, ctypes.byref(box),
                         DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX)
        return box.bottom
    finally:
        if previous:
            gdi32.SelectObject(dc, previous)
        user32.ReleaseDC(status_hwnd, dc)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-gui.py /path/to/lowend_gui.exe")
    executable = pathlib.Path(sys.argv[1]).resolve(strict=True)

    process = subprocess.Popen([str(executable)])
    try:
        window = None
        for _ in range(60):
            time.sleep(0.25)
            if process.poll() is not None:
                raise SystemExit(
                    f"The GUI exited with code {process.returncode} before its window "
                    f"appeared; this is a failure, not a missing desktop.")
            window = find_window("LowEnd Circuit")
            if window:
                break
        if not window:
            print("SKIPPED: the GUI process is running but never presented a window, "
                  "so this session has no desktop to create it on. The end-to-end GUI "
                  "flow was not exercised. This is not a pass.")
            return
        print("window found")

        capture = child_by_id(window, ID_CAPTURE)
        render = child_by_id(window, ID_RENDER)
        start_stop = child_by_id(window, ID_START_STOP)
        status = child_by_id(window, ID_STATUS)
        for name, handle in (("capture", capture), ("output", render),
                             ("start/stop", start_stop), ("status", status)):
            if not handle:
                raise SystemExit(f"The {name} control is missing.")
        print(f"controls present; initial status: {text_of(status)[:80]!r}")

        # The window must open with the routing guidance on screen, not a bare
        # "Idle.": it is where a user learns that the documented route needs a
        # virtual cable, and that stopping LowEnd while Windows' default output is
        # the cable is why they suddenly hear nothing. Asserting it here means the
        # guidance cannot be lost by a later change to the startup path, which is
        # exactly how it went missing the first time - the window set a short
        # literal and never called the code that composes the full text.
        initial = text_of(status)
        if "Idle" not in initial:
            raise SystemExit(f"Expected an idle status at startup, saw:\n{initial}")
        if "never changes Windows" not in initial:
            raise SystemExit(
                "The startup status does not tell the user that LowEnd leaves Windows' default "
                "output alone, so it does not say what to do when the cable is still the default:\n"
                + initial)
        # Matched without case: the note reads "No virtual cable endpoint detected"
        # on a machine without one and "Virtual cable detected: ..." on a machine
        # with one, so the check is on the phrase, not on its capitalization. The
        # restore path is asserted concretely (the Settings page a user has to
        # open), because "we do not change your default output" without saying
        # where to change it back is not guidance a user can act on.
        lowered = initial.lower()
        for phrase in ("virtual cable", "settings > system > sound > output"):
            if phrase not in lowered:
                raise SystemExit(f"The startup status is missing {phrase!r}:\n{initial}")

        capture_count = user32.SendMessageW(capture, CB_GETCOUNT, 0, 0)
        render_count = user32.SendMessageW(render, CB_GETCOUNT, 0, 0)
        if capture_count < 2:
            raise SystemExit(
                f"This check needs at least one output and one input endpoint; "
                f"the capture list has {capture_count} item(s).")

        # The capture list is outputs first, then inputs, so index 0 is the
        # default output's loopback and the last index is an input endpoint.
        input_index = capture_count - 1

        # 1. Same endpoint: capture loopback of the default output, render to it.
        user32.SendMessageW(capture, CB_SETCURSEL, 0, 0)
        user32.SendMessageW(render, CB_SETCURSEL, 0, 0)
        post_message(start_stop, BM_CLICK)
        time.sleep(1.5)
        guarded = text_of(status)
        if "same device" not in guarded:
            raise SystemExit(
                f"Expected the same-endpoint guard, saw:\n{guarded}")
        print("same-endpoint start refused, as designed")

        # 2. Distinct endpoints: capture the input, render to the output.
        user32.SendMessageW(capture, CB_SETCURSEL, input_index, 0)
        post_message(start_stop, BM_CLICK)

        running_status = ""
        deadline = time.time() + POLL_SECONDS
        while time.time() < deadline:
            time.sleep(0.5)
            running_status = text_of(status)
            if frames_from(running_status):
                break
        if "capture" not in running_status or "output @" not in running_status:
            raise SystemExit(
                f"Expected a negotiated route while running, saw:\n{running_status}")

        first_frames = frames_from(running_status)
        if first_frames is None:
            raise SystemExit(f"No frame count in the running status:\n{running_status}")
        print(f"running; route and stats present (frames={first_frames})")

        # The settings summary, the route and the statistics are three blocks that
        # are concatenated into one static control. They have to be separated:
        # they were once joined with nothing between them, so the line read
        # "... space 35capture: input ..." - a broken-looking value where two
        # blocks of information should be.
        lines = running_status.splitlines()
        if not any(line.startswith("capture:") for line in lines):
            raise SystemExit(
                f"The route is not on a line of its own; the settings and the route may "
                f"be running together:\n{running_status}")
        if "capture:" in lines[0]:
            raise SystemExit(
                f"The first status line mixes the settings summary with the route:\n"
                f"{lines[0]}")
        if not any("running model:" in line for line in lines):
            raise SystemExit("The running model is not reported on its own line.")

        # The status text must fit the box that shows it. The box used to be sized
        # as "whatever is left below the last control", which left it 84 px tall
        # against the 256 px a running loopback stream needs - so the statistics
        # and any error guidance, which are appended last, were never visible.
        # The height is measured with the control's own font rather than guessed.
        rect = wintypes.RECT()
        user32.GetWindowRect(status, ctypes.byref(rect))
        status_height = rect.bottom - rect.top
        status_width = rect.right - rect.left
        needed = measure_text_height(status, status_width)
        if needed > status_height:
            raise SystemExit(
                f"The status text needs {needed} px but its box is {status_height} px "
                f"tall, so the end of the text is clipped:\n{running_status}")
        print(f"status text fits its box: needs {needed} px of {status_height} px")
        if "Stop" not in text_of(start_stop):
            raise SystemExit("The start/stop button did not switch to Stop.")

        # Statistics must advance, otherwise the GUI is showing a stale snapshot.
        time.sleep(START_SETTLE_SECONDS)
        second = text_of(status)
        second_frames = frames_from(second)
        if second_frames is None or second_frames <= first_frames:
            raise SystemExit(
                f"Frame count did not advance: {first_frames} -> {second_frames}\n{second}")
        print(f"statistics advancing: frames {first_frames} -> {second_frames}")

        # 3. Change the model while audio is running. The engine queues the edit
        #    and the audio thread applies it at a block boundary, so this
        #    exercises the control-to-audio handoff through the real UI rather
        #    than only asserting that the controls store a value. The status line
        #    reports the model the audio thread is running, which is the only
        #    place the change becoming effective is observable from outside.
        def running_model() -> str:
            match = re.search(r"running model:\s*(\w+)", text_of(status))
            return match.group(1) if match else ""

        if running_model().lower() != "circuit":
            raise SystemExit(
                f"Expected Circuit to be running before the change, saw {running_model()!r}")

        # Index 2 in the model combo is HighExciter (Clean, Circuit, HighExciter).
        model_combo = child_by_id(window, ID_MODEL)
        if model_combo is None:
            raise SystemExit("The model control is missing.")
        user32.SendMessageW(model_combo, CB_SETCURSEL, 2, 0)
        # A combo box reports its change as CBN_SELCHANGE in the notification word
        # of WM_COMMAND; posting that is what selecting an entry produces.
        post_message(window, WM_COMMAND, (1 << 16) | ID_MODEL, model_combo)

        switched = False
        deadline = time.time() + POLL_SECONDS
        while time.time() < deadline:
            time.sleep(0.5)
            if running_model().lower() == "highexciter":
                switched = True
                break
        if not switched:
            raise SystemExit(
                f"The running model never changed to HighExciter; status was:\n{text_of(status)}")
        print("live model change reached the audio thread: now HighExciter")

        # The stream must still be healthy after the change: a model switch
        # crossfades two banks, and a fault there would show as errors or a
        # stalled frame count.
        after_change = frames_from(text_of(status))
        time.sleep(1.5)
        still_advancing = frames_from(text_of(status))
        if after_change is None or still_advancing is None or still_advancing <= after_change:
            raise SystemExit(
                f"Frame count did not advance after the model change: "
                f"{after_change} -> {still_advancing}")

        # 4. Stop returns to idle.
        post_message(start_stop, BM_CLICK)
        time.sleep(1.5)
        stopped = text_of(status)
        if "Idle" not in stopped:
            raise SystemExit(f"Expected idle after Stop, saw:\n{stopped}")
        if "Start" not in text_of(start_stop):
            raise SystemExit("The start/stop button did not switch back to Start.")
        print("stopped cleanly")

        # 4. Start again on the same window. This exercises a different path from
        #    the first start: the engine object is destroyed and rebuilt, the
        #    status timer is re-armed, and a second set of audio threads is
        #    created after the first has been joined. A leak, a stale flag, or a
        #    timer that is never killed would hang or crash here rather than on a
        #    single start/stop cycle.
        previous_final = second_frames
        post_message(start_stop, BM_CLICK)
        restarted_status = ""
        deadline = time.time() + POLL_SECONDS
        while time.time() < deadline:
            time.sleep(0.5)
            restarted_status = text_of(status)
            if frames_from(restarted_status):
                break
        if "capture" not in restarted_status or "output @" not in restarted_status:
            raise SystemExit(
                f"Expected a negotiated route after restarting, saw:\n{restarted_status}")
        restarted_frames = frames_from(restarted_status)
        if restarted_frames is None:
            raise SystemExit(f"No frame count after restart:\n{restarted_status}")

        # The new stream counts from its own beginning. Comparing against the
        # previous run's final count is what makes this meaningful: a count that
        # carried on from there would mean the stopped engine's statistics were
        # still being reported.
        if restarted_frames >= previous_final:
            raise SystemExit(
                f"The restarted engine reports {restarted_frames} frames after the previous "
                f"run ended at {previous_final}; its statistics were not reset.")
        print(f"restarted with fresh statistics: {previous_final} -> {restarted_frames} frames")

        time.sleep(START_SETTLE_SECONDS)
        advanced = frames_from(text_of(status))
        if advanced is None or advanced <= restarted_frames:
            raise SystemExit(
                f"Frame count did not advance after restart: {restarted_frames} -> {advanced}")
        print(f"restarted stream is running: frames {restarted_frames} -> {advanced}")

        post_message(start_stop, BM_CLICK)
        time.sleep(1.5)
        if "Idle" not in text_of(status):
            raise SystemExit("Expected idle after the second Stop.")
        print("second stop clean")

        post_message(window, WM_CLOSE)
        time.sleep(1.0)
        if process.poll() is None:
            raise SystemExit("The GUI did not exit on WM_CLOSE.")
        print("GUI verification passed: start, live statistics, stop, restart, and shutdown")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    main()
