"""Verify the GUI keeps its device selection when the device list is refreshed.

"Refresh devices" rebuilds both combo boxes from the endpoint enumerator. The
rebuild preserves the render selection but the capture selection has to be
preserved the same way, and that is easy to lose: the capture list is built from
two sources (every output endpoint as a loopback candidate, then every input
endpoint), so its indices shift with the hardware.

When the capture selection was not preserved, pressing Refresh silently moved the
capture source back to the first entry - the default output's system audio, which
is the same endpoint the default render selection points at. The configuration a
user had chosen turned into one the self-capture guard refuses, so the next Start
failed for a reason they never picked.

This checks the whole consequence, not just the combo index:
  1. select a non-default capture entry (an input endpoint),
  2. refresh, and require the selection to survive,
  3. run the engine and require the negotiated capture route to be identical
     before and after a refresh taken while the stream is live.

No audio hardware is needed for step 2; step 3 needs two endpoints, and reports
SKIPPED rather than passing when it cannot open them.

Usage:  python scripts/check-windows-gui-refresh.py /path/to/lowend_gui.exe
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
user32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SendMessageW.restype = ctypes.c_longlong
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.mouse_event.argtypes = [wintypes.DWORD] * 5

CB_GETCOUNT, CB_GETCURSEL, CB_SETCURSEL = 0x0146, 0x0147, 0x014E
CB_GETLBTEXT = 0x0148
MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004

ID_CAPTURE, ID_RENDER, ID_REFRESH, ID_START_STOP, ID_STATUS = 1000, 1001, 1002, 1013, 1014


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


def text_of(hwnd) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return buffer.value


def item_text(combo, index) -> str:
    length = user32.SendMessageW(combo, 0x0149, index, 0)  # CB_GETLBTEXTLEN
    buffer = ctypes.create_unicode_buffer(length + 2)
    user32.SendMessageW(combo, CB_GETLBTEXT, index, ctypes.cast(buffer, ctypes.c_void_p).value)
    return buffer.value


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-gui-refresh.py /path/to/lowend_gui.exe")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-gui-refresh.py: no such executable: {sys.argv[1]}\n"
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
                  "so this session has no desktop to create it on. The refresh "
                  "behaviour was not observed. This is not a pass.")
            return
        user32.SetForegroundWindow(window)
        time.sleep(0.4)

        children = []

        @WNDENUMPROC
        def collect(hwnd, _):
            children.append(hwnd)
            return True

        user32.EnumChildWindows(window, collect, 0)
        by_id = {user32.GetDlgCtrlID(h): h for h in children}
        rects = {}
        for hwnd in children:
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            rects[hwnd] = rect

        for name, control_id in (("capture", ID_CAPTURE), ("render", ID_RENDER),
                                 ("refresh", ID_REFRESH), ("start", ID_START_STOP),
                                 ("status", ID_STATUS)):
            if control_id not in by_id:
                raise SystemExit(f"The {name} control is missing.")

        def click(hwnd):
            rect = rects[hwnd]
            user32.SetCursorPos((rect.left + rect.right) // 2, (rect.top + rect.bottom) // 2)
            time.sleep(0.2)
            user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            time.sleep(0.08)
            user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
            time.sleep(0.8)

        capture = by_id[ID_CAPTURE]
        count = user32.SendMessageW(capture, CB_GETCOUNT, 0, 0)
        if count < 2:
            print("SKIPPED: the capture list has fewer than two entries, so there is "
                  "no non-default selection to preserve. This is not a pass.")
            return

        # Pick a non-default capture entry: the last one is an input endpoint,
        # which is the selection the defect moved away from.
        wanted = count - 1
        user32.SendMessageW(capture, CB_SETCURSEL, wanted, 0)
        selected = item_text(capture, wanted)

        click(by_id[ID_REFRESH])

        now = user32.SendMessageW(capture, CB_GETCURSEL, 0, 0)
        problems = []
        if now != wanted:
            problems.append(
                f"the capture selection moved from index {wanted} ({selected!r}) to "
                f"index {now} ({item_text(capture, now)!r}) across a refresh")

        # The negotiated route must also be stable, since that is what the user
        # actually hears. This needs a second endpoint to render to.
        click(by_id[ID_START_STOP])
        deadline = time.time() + 8
        route_before = ""
        while time.time() < deadline:
            time.sleep(0.5)
            match = re.search(r"(capture:\s*(?:input|loopback)[^\n]*)", text_of(by_id[ID_STATUS]))
            if match:
                route_before = match.group(1)
                break

        if not route_before:
            print("SKIPPED: the engine did not reach a negotiated route (this machine "
                  "has no usable pair of endpoints), so the live half of this check "
                  "was not exercised. This is not a pass.")
        else:
            click(by_id[ID_REFRESH])
            time.sleep(1.5)
            match = re.search(r"(capture:\s*(?:input|loopback)[^\n]*)", text_of(by_id[ID_STATUS]))
            route_after = match.group(1) if match else ""
            if route_after != route_before:
                problems.append(
                    f"the capture route changed across a live refresh:\n"
                    f"    before: {route_before}\n"
                    f"    after:  {route_after}")
            if process.poll() is not None:
                problems.append("the process exited during the live refresh")

        # Stop, whichever path ran.
        if "Stop" in text_of(by_id[ID_START_STOP]):
            click(by_id[ID_START_STOP])
            time.sleep(1.0)

        if problems:
            for problem in problems:
                print(f"  MISMATCH: {problem}", file=sys.stderr)
            raise SystemExit("Refreshing the device list did not preserve the selection.")

        print(f"device selection survives a refresh: capture kept {selected!r} "
              f"(index {wanted})" + (f", and the live route was unchanged" if route_before else ""))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    main()
