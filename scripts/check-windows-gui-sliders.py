"""Verify the GUI slider path with real mouse drags.

The Windows guide previously listed this as unverified. Driving the trackbars
with TBM_SETPOS would have been a weak substitute: a trackbar reports user
input through WM_HSCROLL, and the panel needs a handler for it. That handler was
missing, so dragging a slider moved the thumb and changed the DSP value while the
number beside it and the status line kept showing the old value. Only a real drag
exposes that - a synthesized position update does not send the notification.

So this presses the mouse on each thumb, drags it, and checks that the readout
follows the thumb. The readouts are painted from the same `readSettings()` the
engine receives, so a readout that disagrees with the thumb is a disagreement
between what the user sees and what is being applied.

No audio device is needed: nothing is started, the sliders are only dragged.

Usage:  python scripts/check-windows-gui-sliders.py /path/to/lowend_gui.exe
"""
import ctypes
import pathlib
import re
import subprocess
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumChildWindows.argtypes = [wintypes.HWND, WNDENUMPROC, wintypes.LPARAM]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SendMessageW.restype = ctypes.c_longlong
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.mouse_event.argtypes = [wintypes.DWORD] * 5

TBM_GETPOS = 0x0400
MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004
ID_STATUS = 1014

# Each slider: (name, control id, spec minimum, scale). The readout is
# `(minimum + position) / scale`, which is the conversion the panel performs.
SLIDERS = [
    ("LowEnd", 1005, 0, 10),
    ("Body", 1006, 0, 10),
    ("Output", 1007, -18 * 10, 10),
    ("Space", 1009, 0, 10),
    ("Speaker width", 1010, 60, 100),
    ("Listener X", 1011, -300, 100),
    ("Listener Z", 1012, -280, 100),
]

# Fractions of the trackbar to drag to. Both ends plus a middle: an offset error
# shows at the extremes, a rounding error in the middle.
TARGETS = (0.05, 0.5, 0.95)


def find_window(title: str):
    result = []

    @WNDENUMPROC
    def callback(hwnd, _):
        length = user32.GetWindowTextLengthW(hwnd)
        if length:
            buffer = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buffer, length + 1)
            if buffer.value == title and user32.IsWindowVisible(hwnd):
                result.append(hwnd)
                return False
        return True

    user32.EnumWindows(callback, 0)
    return result[0] if result else None


def class_of(hwnd) -> str:
    buffer = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buffer, 256)
    return buffer.value


def text_of(hwnd) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return buffer.value


def parse_number(text: str):
    match = re.match(r"^\s*(-?\d+(?:\.\d+)?)", text)
    return float(match.group(1)) if match else None


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-gui-sliders.py /path/to/lowend_gui.exe")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-gui-sliders.py: no such executable: {sys.argv[1]}\n"
                         "build it first: scripts\\build-windows-cli.bat Release")

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
                  "so this session has no desktop to create it on. The slider path "
                  "was not exercised. This is not a pass.")
            return
        # Real mouse input goes to the foreground window.
        user32.SetForegroundWindow(window)
        time.sleep(0.5)

        children = []

        @WNDENUMPROC
        def collect(hwnd, _):
            children.append(hwnd)
            return True

        user32.EnumChildWindows(window, collect, 0)

        rects = {}
        for hwnd in children:
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            rects[hwnd] = rect

        bars = {user32.GetDlgCtrlID(h): h for h in children
                if class_of(h) == "msctls_trackbar32"}
        status = next((h for h in children if user32.GetDlgCtrlID(h) == ID_STATUS), None)
        if status is None:
            raise SystemExit("The status line is missing.")

        def value_label(bar):
            bar_rect = rects[bar]
            candidates = [
                h for h in children
                if class_of(h) == "Static"
                and rects[h].left >= bar_rect.right - 4
                and abs(rects[h].top - bar_rect.top) <= 12
            ]
            return min(candidates, key=lambda h: rects[h].left) if candidates else None

        def drag(bar, fraction):
            rect = rects[bar]
            position = user32.SendMessageW(bar, TBM_GETPOS, 0, 0)
            span = rect.right - rect.left - 14
            thumb_x = rect.left + int(span * position / 1000) + 7
            target_x = rect.left + int(span * fraction) + 7
            y = (rect.top + rect.bottom) // 2
            user32.SetCursorPos(thumb_x, y)
            time.sleep(0.2)
            user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            time.sleep(0.15)
            for step in range(1, 16):
                user32.SetCursorPos(thumb_x + (target_x - thumb_x) * step // 15, y)
                time.sleep(0.04)
            time.sleep(0.15)
            user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
            time.sleep(0.7)
            return user32.SendMessageW(bar, TBM_GETPOS, 0, 0)

        problems = []
        checked = 0
        moved = 0
        for name, control_id, minimum, scale in SLIDERS:
            bar = bars.get(control_id)
            if bar is None:
                raise SystemExit(f"The {name} trackbar (id {control_id}) is missing.")
            label = value_label(bar)
            if label is None:
                raise SystemExit(f"No value readout found beside the {name} slider.")

            for fraction in TARGETS:
                before = user32.SendMessageW(bar, TBM_GETPOS, 0, 0)
                position = drag(bar, fraction)
                if position != before:
                    moved += 1
                expected = (minimum + position) / scale
                shown = parse_number(text_of(label))
                checked += 1
                if shown is None:
                    problems.append(f"{name}: readout shows no number ({text_of(label)!r})")
                    continue
                # One decimal at the coarse scale, two at the fine one, so
                # compare within half of the last displayed digit.
                tolerance = 0.05 if scale == 10 else 0.005
                if abs(shown - expected) > tolerance:
                    problems.append(
                        f"{name}: thumb at position {position} means {expected:g}, "
                        f"but the readout shows {shown:g}")

        # Real mouse input only reaches the window when the process has an input
        # desktop. A headless session cannot move a thumb at all, which is an
        # environment limitation rather than a defect - and it is distinguishable
        # from the real defect, where the thumb moves and the readout does not.
        if moved == 0:
            print("SKIPPED: real mouse input did not reach the window in this "
                  "environment (no input desktop), so the slider path was not "
                  "exercised. This is not a pass.")
            return

        if problems:
            for problem in problems:
                print(f"  MISMATCH: {problem}", file=sys.stderr)
            raise SystemExit(f"{len(problems)} slider reading(s) did not follow the drag.")

        print(f"slider path verified with real drags: {checked} drag(s) across "
              f"{len(SLIDERS)} sliders; every readout followed its thumb")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    main()
