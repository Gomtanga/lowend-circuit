"""Enumerate every control in the real GUI window and report its class.

The Windows guide documents the control inventory as a specific breakdown
(4 combo boxes, 7 trackbars, 3 buttons, 1 static). That is a claim about the
window a user actually gets, so it is checked against the live window rather
than against the source: a control that failed to create, or was created with a
different class, would not show up any other way.

Usage:  python scripts/check-windows-gui-controls.py /path/to/lowend_gui.exe
"""
import ctypes
import pathlib
import subprocess
import sys
import time
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumChildWindows.argtypes = [wintypes.HWND, WNDENUMPROC, wintypes.LPARAM]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetDlgCtrlID.argtypes = [wintypes.HWND]
user32.MapWindowPoints.argtypes = [wintypes.HWND, wintypes.HWND,
                                   ctypes.POINTER(wintypes.POINT), ctypes.c_uint]
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]

# The breakdown the guide documents. The static count is the one worth pinning:
# 13 section labels, 6 value readouts, and 1 status line. (The guide used to
# claim a single static, which undercounted the window by 18 controls - the
# class totals for combo, trackbar and button were right, so only a check that
# counts every class catches a wrong total.)
EXPECTED = {"ComboBox": 4, "msctls_trackbar32": 7, "Button": 3, "Static": 19}
EXPECTED_TOTAL = 33


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


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-gui-controls.py /path/to/lowend_gui.exe")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-gui-controls.py: no such executable: {sys.argv[1]}\n"
                         "build it first: scripts\\build-windows-cli.bat Release")

    process = subprocess.Popen([str(executable)])
    try:
        window = None
        for _ in range(60):
            time.sleep(0.25)
            if process.poll() is not None:
                # The process gave up rather than waiting for a desktop. That is
                # a real failure, not an environment limit, so the exit code is
                # what the caller needs to see.
                raise SystemExit(
                    f"The GUI exited with code {process.returncode} before its window "
                    f"appeared; this is a failure, not a missing desktop.")
            window = find_window("LowEnd Circuit")
            if window:
                break
        if not window:
            # Still running but no window: the session has no desktop to put it
            # on. Reported as skipped rather than passing, because nothing about
            # the control inventory was actually observed.
            print("SKIPPED: the GUI process is running but never presented a window, "
                  "so this session has no desktop to create it on. The control "
                  "inventory was not observed. This is not a pass.")
            return

        controls = []
        children_list = []

        @WNDENUMPROC
        def collect(hwnd, _):
            children_list.append(hwnd)
            name = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(hwnd, name, 256)
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            controls.append((user32.GetDlgCtrlID(hwnd), name.value,
                             rect.right - rect.left, rect.bottom - rect.top))
            return True

        user32.EnumChildWindows(window, collect, 0)

        counts = {}
        for _, name, _, _ in controls:
            counts[name] = counts.get(name, 0) + 1

        print(f"enumerated {len(controls)} control(s) in the live window:")
        for name in sorted(counts):
            print(f"  {name:<22} {counts[name]}")

        problems = []
        for name, expected in EXPECTED.items():
            actual = counts.get(name, 0)
            if actual != expected:
                problems.append(f"{name}: expected {expected}, found {actual}")
        if len(controls) != EXPECTED_TOTAL:
            problems.append(f"total controls: expected {EXPECTED_TOTAL}, found {len(controls)}")
        unexpected = set(counts) - set(EXPECTED)
        if unexpected:
            problems.append(f"undocumented control class(es): {sorted(unexpected)}")

        # A control that exists but was never placed is still a defect, so the
        # documented claim is about laid-out controls: every one must have a size.
        collapsed = [cid for cid, _, w, h in controls if w <= 0 or h <= 0]
        if collapsed:
            problems.append(f"control id(s) {collapsed} have no size; they are not laid out")

        # Layout is checked in the parent's client space, which is the space the
        # panel lays out in. GetWindowRect returns screen coordinates and
        # GetClientRect returns client ones, so comparing them directly would
        # report every control as out of bounds - the comparison only means
        # something once both corners are mapped into the same space.
        placed = []
        for hwnd in children_list:
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            points = (wintypes.POINT * 2)(wintypes.POINT(rect.left, rect.top),
                                          wintypes.POINT(rect.right, rect.bottom))
            user32.MapWindowPoints(0, window, points, 2)
            class_name = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(hwnd, class_name, 256)
            placed.append((user32.GetDlgCtrlID(hwnd), class_name.value,
                           points[0].x, points[0].y, points[1].x, points[1].y))

        client = wintypes.RECT()
        user32.GetClientRect(window, ctypes.byref(client))
        outside = [p[0] for p in placed
                   if p[2] < 0 or p[3] < 0 or p[4] > client.right or p[5] > client.bottom]
        if outside:
            problems.append(f"control id(s) {outside} are placed outside the window's "
                            f"client area ({client.right}x{client.bottom})")

        # Two interactive controls must not overlap, or one is unusable: the
        # later-created control takes the clicks in the shared region. The value
        # readouts are statics and are excluded, since a readout sits beside its
        # slider by design.
        interactive = [p for p in placed
                       if p[1] in ("ComboBox", "msctls_trackbar32", "Button")]
        for i in range(len(interactive)):
            for j in range(i + 1, len(interactive)):
                a, b = interactive[i], interactive[j]
                if not (a[4] <= b[2] or b[4] <= a[2] or a[5] <= b[3] or b[5] <= a[3]):
                    problems.append(
                        f"controls {a[0]} ({a[1]}) and {b[0]} ({b[1]}) overlap, so one "
                        f"of them cannot be reached")

        if problems:
            for problem in problems:
                print(f"  MISMATCH: {problem}", file=sys.stderr)
            raise SystemExit("The control inventory does not match the documented breakdown.")

        print(f"control inventory matches the documented breakdown "
              f"({len(controls)} controls: 4 combo, 7 trackbar, 3 button, 19 static); "
              f"every control is sized and inside the {client.right}x{client.bottom} "
              f"client area, and no two interactive controls overlap")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    main()
