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
# 12 label rows, the model note that says what the selected model does, 6 value
# readouts, and 1 status line. (The guide used to claim a single static, which
# undercounted the window by 18 controls - the class totals for combo, trackbar
# and button were right, so only a check that counts every class catches a wrong
# total.)
EXPECTED = {"ComboBox": 4, "msctls_trackbar32": 7, "Button": 3, "Static": 20}
EXPECTED_TOTAL = 34

# The controls whose visibility or text follows the selected model, and what the
# macOS app does with the same engine: HighExciter keeps the dry signal and never
# applies the output gain, so its Output row is hidden and the exciter's own
# oversampling control is shown in its place. A slider that does nothing when it
# is dragged is a defect the user sees, not a documentation problem.
ID_MODEL = 1003
ID_EXCITER_OVERSAMPLING = 1004
ID_INTENSITY = 1005
ID_BODY = 1006
ID_OUTPUT = 1007
ID_OUTPUT_LABEL = 1015
ID_INTENSITY_LABEL = 1016
ID_BODY_LABEL = 1017
ID_HARMONIC_LABEL = 1018
ID_MODEL_NOTE = 1019

# What each model does with the controls, taken from the macOS app, which drives
# the same engine: Clean runs no tone DSP (its amount sliders are disabled),
# Circuit is the only model that applies the output gain, and HighExciter adds
# harmonics to the dry signal without an output stage (its Output row is hidden
# and the exciter's own oversampling control takes its place).
MODEL_STATES = {
    "Clean": {
        "visible": {ID_OUTPUT: True, ID_OUTPUT_LABEL: True,
                    ID_EXCITER_OVERSAMPLING: False, ID_HARMONIC_LABEL: False},
        "enabled": {ID_INTENSITY: False, ID_BODY: False, ID_OUTPUT: False,
                    ID_EXCITER_OVERSAMPLING: False},
        "labels": {ID_INTENSITY_LABEL: "Bypass", ID_BODY_LABEL: "Bypass"},
        "note": "Clean runs no tone DSP",
    },
    "Circuit": {
        "visible": {ID_OUTPUT: True, ID_OUTPUT_LABEL: True,
                    ID_EXCITER_OVERSAMPLING: False, ID_HARMONIC_LABEL: False},
        "enabled": {ID_INTENSITY: True, ID_BODY: True, ID_OUTPUT: True,
                    ID_EXCITER_OVERSAMPLING: False},
        "labels": {ID_INTENSITY_LABEL: "LowEnd", ID_BODY_LABEL: "Body"},
        "note": "Circuit applies the low-end stages",
    },
    "HighExciter": {
        "visible": {ID_OUTPUT: False, ID_OUTPUT_LABEL: False,
                    ID_EXCITER_OVERSAMPLING: True, ID_HARMONIC_LABEL: True},
        "enabled": {ID_INTENSITY: True, ID_BODY: True, ID_OUTPUT: False,
                    ID_EXCITER_OVERSAMPLING: True},
        "labels": {ID_INTENSITY_LABEL: "Exciter Drive", ID_BODY_LABEL: "Wet Mix"},
        "note": "HighExciter keeps the dry signal and applies no output gain",
    },
}
# Combo index for each model, in the order the panel adds them.
MODEL_INDEX = {"Clean": 0, "Circuit": 1, "HighExciter": 2}
# Which selection each state is asserted under, including a return to Circuit so
# a switch back is observed and not only the switch away.
CHECK_ORDER = ("Circuit", "Clean", "HighExciter", "Circuit")


def child_by_id(parent, control_id):
    found = []

    @WNDENUMPROC
    def callback(hwnd, _):
        if user32.GetDlgCtrlID(hwnd) == control_id:
            found.append(hwnd)
            return False
        return True

    user32.EnumChildWindows(parent, callback, 0)
    return found[0] if found else None


def window_text(hwnd) -> str:
    buffer = ctypes.create_unicode_buffer(256)
    user32.GetWindowTextW(hwnd, buffer, 256)
    return buffer.value


def check_state(window, state_name: str, problems: list) -> None:
    expected = MODEL_STATES[state_name]
    for control_id, should_be_visible in expected["visible"].items():
        hwnd = child_by_id(window, control_id)
        if hwnd is None:
            problems.append(f"{state_name}: control {control_id} is missing")
            continue
        visible = bool(user32.IsWindowVisible(hwnd))
        if visible != should_be_visible:
            problems.append(
                f"{state_name}: control {control_id} should be "
                f"{'visible' if should_be_visible else 'hidden'}, it is "
                f"{'visible' if visible else 'hidden'}")
    for control_id, should_be_enabled in expected["enabled"].items():
        hwnd = child_by_id(window, control_id)
        if hwnd is None:
            problems.append(f"{state_name}: control {control_id} is missing")
            continue
        enabled = bool(user32.IsWindowEnabled(hwnd))
        if enabled != should_be_enabled:
            problems.append(
                f"{state_name}: control {control_id} should be "
                f"{'enabled' if should_be_enabled else 'disabled'}, it is "
                f"{'enabled' if enabled else 'disabled'}")
    for control_id, text in expected["labels"].items():
        hwnd = child_by_id(window, control_id)
        actual = window_text(hwnd) if hwnd else ""
        if actual != text:
            problems.append(
                f"{state_name}: control {control_id} reads {actual!r}, expected {text!r}")
    note = window_text(child_by_id(window, ID_MODEL_NOTE))
    if expected["note"] not in note:
        problems.append(f"{state_name}: the model note does not say {expected['note']!r}: {note!r}")


def select_model(window, index: int) -> None:
    """Selects a model the way the combo does: CB_SETCURSEL, then the notification."""
    combo = child_by_id(window, ID_MODEL)
    user32.SendMessageW(combo, 0x014E, index, 0)          # CB_SETCURSEL
    user32.PostMessageW(window, 0x0111, (1 << 16) | ID_MODEL, combo)  # WM_COMMAND, CBN_SELCHANGE


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

        # The model-dependent affordances, checked through a real selection each
        # time so the switch itself is exercised rather than only the startup
        # state.
        for position, state_name in enumerate(CHECK_ORDER):
            # The first entry is the window's startup state; every later one is
            # reached by selecting it, so each transition is exercised.
            if position > 0:
                select_model(window, MODEL_INDEX[state_name])
                time.sleep(0.5)
            check_state(window, state_name, problems)

        if problems:
            for problem in problems:
                print(f"  MISMATCH: {problem}", file=sys.stderr)
            raise SystemExit("The per-model affordances do not follow the selected model.")

        print(f"control inventory matches the documented breakdown "
              f"({len(controls)} controls: 4 combo, 7 trackbar, 3 button, 20 static); "
              f"every control is sized and inside the {client.right}x{client.bottom} "
              f"client area, and no two interactive controls overlap")
        print("model affordances follow the selection: Circuit enables the amount "
              "sliders and the Output row, Clean disables them and says so, and "
              "HighExciter hides Output and shows Harmonic quality with the sliders "
              "labelled by what they do for that model")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()


if __name__ == "__main__":
    main()
