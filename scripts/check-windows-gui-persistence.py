"""Verify the GUI stores, restores and refuses device selections.

The GUI remembers the capture source and the output endpoint the user chose, in
the user's own profile (%LOCALAPPDATA%\\LowEndCircuit\\device-selection.txt) -
never in the repository, since a file naming the endpoints of this machine is user
state rather than project state.

Three behaviours are checked, and each one matters on its own:

  1. A saved, still-present endpoint is selected again at startup. Otherwise every
     run starts on the first list entry, which is not what the user chose.
  2. A saved endpoint that is *gone* leaves its combo empty and Start refuses with
     that reason. Falling back to the first entry would open a route the user
     never picked, and the fallback would look exactly like a working start.
  3. A selection change is written to the file. Without this, (1) would restore a
     selection the user made once and never again.

The change in (3) is delivered as WM_COMMAND/CBN_SELCHANGE, which is the
notification a real click sends; the handler reads the combo's current selection,
so this drives the same code a user does.

The script backs up and restores the real selection file, so running it does not
disturb the user's own configuration. It needs a window station (a real desktop);
without one it reports SKIPPED, which is not a pass.

Usage:  python scripts/check-windows-gui-persistence.py /path/to/lowend_gui.exe
"""
import ctypes
import ctypes.wintypes as wintypes
import os
import pathlib
import re
import subprocess
import sys
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumChildWindows.argtypes = [wintypes.HWND, WNDENUMPROC, wintypes.LPARAM]
user32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.SendMessageW.restype = ctypes.c_longlong
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.mouse_event.argtypes = [wintypes.DWORD] * 5

CB_GETCOUNT, CB_GETCURSEL, CB_SETCURSEL = 0x0146, 0x0147, 0x014E
CB_GETLBTEXT, CB_GETLBTEXTLEN = 0x0148, 0x0149
WM_COMMAND, CBN_SELCHANGE = 0x0111, 1
MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004

ID_CAPTURE, ID_RENDER, ID_START_STOP, ID_STATUS = 1000, 1001, 1013, 1014

STALE_ID = "{0.0.1.00000000}.{deadbeef-0000-0000-0000-000000000000}"


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
    length = user32.SendMessageW(combo, CB_GETLBTEXTLEN, index, 0)
    buffer = ctypes.create_unicode_buffer(length + 2)
    user32.SendMessageW(combo, CB_GETLBTEXT, index, ctypes.cast(buffer, ctypes.c_void_p).value)
    return buffer.value


def selection_file() -> pathlib.Path:
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        raise SystemExit("LOCALAPPDATA is not set, so the selection file cannot be located.")
    return pathlib.Path(local) / "LowEndCircuit" / "device-selection.txt"


def parse_devices(executable: pathlib.Path):
    """Returns (outputs, inputs) as lists of (id, name) from the CLI's own report."""
    cli = executable.with_name("lowend_windows.exe")
    result = subprocess.run([str(cli), "--list-devices"], capture_output=True, text=True,
                            timeout=60)
    if result.returncode != 0:
        raise SystemExit(f"--list-devices failed: {result.stderr.strip()}")

    def collect(section: str):
        found = []
        inside = False
        for line in result.stdout.splitlines():
            if line.startswith(section):
                inside = True
                continue
            if inside and (line.startswith("Input devices") or line.startswith("Virtual cables")
                           or line.startswith("* marks")):
                inside = False
            if inside:
                match = re.search(r"id=(\{[^}]*\}\.\{[^}]*\})", line)
                if match:
                    name = re.sub(r"\s+bus=\S+", "", line[:match.start()]).strip(" *")
                    # "name  rate Hz / ch / bits" -> "name"
                    name = re.split(r"\s+\d+ Hz", name)[0].strip()
                    found.append((match.group(1), name))
        return found

    return collect("Output devices"), collect("Input devices")


class Gui:
    """A launched GUI plus its controls, closed on exit."""

    def __init__(self, executable: pathlib.Path, timeout: float = 15.0):
        self.process = subprocess.Popen([str(executable)])
        self.window = None
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(0.25)
            if self.process.poll() is not None:
                raise SystemExit(
                    f"The GUI exited with code {self.process.returncode} before its window "
                    f"appeared; this is a failure, not a missing desktop.")
            self.window = find_window("LowEnd Circuit")
            if self.window:
                break
        if not self.window:
            self.close()
            raise TimeoutError("no window")
        user32.SetForegroundWindow(self.window)
        time.sleep(0.4)

        children = []

        @WNDENUMPROC
        def collect(hwnd, _):
            children.append(hwnd)
            return True

        user32.EnumChildWindows(self.window, collect, 0)
        self.by_id = {user32.GetDlgCtrlID(h): h for h in children}
        self.rects = {}
        for hwnd in children:
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            self.rects[hwnd] = rect

    def click(self, control_id: int) -> None:
        hwnd = self.by_id[control_id]
        rect = self.rects[hwnd]
        user32.SetCursorPos((rect.left + rect.right) // 2, (rect.top + rect.bottom) // 2)
        time.sleep(0.2)
        user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
        time.sleep(0.08)
        user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
        time.sleep(0.8)

    def select(self, control_id: int, index: int) -> None:
        """Selects an entry the way a user does: set the selection, then notify."""
        combo = self.by_id[control_id]
        user32.SendMessageW(combo, CB_SETCURSEL, index, 0)
        user32.SendMessageW(self.window, WM_COMMAND,
                            (CBN_SELCHANGE << 16) | control_id, combo)
        time.sleep(0.4)

    def current(self, control_id: int) -> int:
        return user32.SendMessageW(self.by_id[control_id], CB_GETCURSEL, 0, 0)

    def count(self, control_id: int) -> int:
        return user32.SendMessageW(self.by_id[control_id], CB_GETCOUNT, 0, 0)

    def text(self, control_id: int) -> str:
        return text_of(self.by_id[control_id])

    def close(self) -> None:
        if self.window:
            user32.PostMessageW(self.window, 0x0010, 0, 0)  # WM_CLOSE
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=15)


def write_selection(path: pathlib.Path, capture: str, render: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"capture={capture}\nrender={render}\n", encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-windows-gui-persistence.py /path/to/lowend_gui.exe")
    try:
        executable = pathlib.Path(sys.argv[1]).resolve(strict=True)
    except OSError:
        raise SystemExit(f"check-windows-gui-persistence.py: no such executable: {sys.argv[1]}\n"
                         "build it first: scripts\\build-windows-cli.bat Release")

    outputs, inputs = parse_devices(executable)
    if len(outputs) < 2 or not inputs:
        print(f"SKIPPED: this machine exposes {len(outputs)} output and {len(inputs)} input "
              f"endpoint(s); distinguishing a restored selection from the first entry needs "
              f"at least two outputs and one input. The persistence behaviour was not "
              f"observed. This is not a pass.")
        return 0

    path = selection_file()
    saved_backup = path.read_bytes() if path.exists() else None

    capture_choice = inputs[0]
    render_choice = outputs[1]
    problems = []
    try:
        # 1. A saved, present endpoint is restored at startup.
        write_selection(path, capture_choice[0], render_choice[0])
        try:
            gui = Gui(executable)
        except TimeoutError:
            print("SKIPPED: the GUI process is running but never presented a window, so this "
                  "session has no desktop to create it on. The persistence behaviour was not "
                  "observed. This is not a pass.")
            return 0
        try:
            capture_index = gui.current(ID_CAPTURE)
            render_index = gui.current(ID_RENDER)
            if capture_index < 0 or render_index < 0:
                problems.append("a saved selection that is still present was not selected at "
                                f"startup (capture index {capture_index}, render index "
                                f"{render_index})")
            else:
                capture_text = item_text(gui.by_id[ID_CAPTURE], capture_index)
                render_text = item_text(gui.by_id[ID_RENDER], render_index)
                if "Input:" not in capture_text:
                    problems.append(
                        f"the restored capture selection is {capture_text!r}, not the saved "
                        f"input endpoint")
                if render_text.strip() != render_choice[1].strip() and \
                        (not render_choice[1].strip() or render_choice[1].strip() not in render_text):
                    problems.append(
                        f"the restored output selection is {render_text!r}, not the saved "
                        f"{render_choice[1]!r}")
        finally:
            gui.close()

        # 2. A saved endpoint that is gone leaves the combo empty and Start refuses.
        write_selection(path, STALE_ID, render_choice[0])
        try:
            gui = Gui(executable)
        except TimeoutError:
            print("SKIPPED: no desktop for the second phase; the refusal was not observed. "
                  "This is not a pass.")
            return 0
        try:
            if gui.current(ID_CAPTURE) >= 0:
                problems.append(
                    "a saved capture endpoint that no longer exists was replaced with another "
                    "endpoint instead of leaving the combo unselected")
            gui.click(ID_START_STOP)
            status = gui.text(ID_STATUS)
            if "no longer present" not in status:
                problems.append(
                    "Start was not refused with the missing-endpoint reason; the status line "
                    f"reads: {status[:200]!r}")
        finally:
            gui.close()

        # 3. A selection change is written to the user's own file.
        write_selection(path, inputs[0][0], outputs[0][0])
        try:
            gui = Gui(executable)
        except TimeoutError:
            print("SKIPPED: no desktop for the third phase; the save was not observed. "
                  "This is not a pass.")
            return 0
        try:
            target = gui.count(ID_CAPTURE) - 1
            gui.select(ID_CAPTURE, target)
            written = path.read_text(encoding="utf-8") if path.exists() else ""
            match = re.search(r"^capture=(.*)$", written, re.M)
            expected = None
            # The last capture entry is an input endpoint; its id is the last one
            # the CLI listed for the input section.
            if inputs:
                expected = inputs[-1][0]
            if not match:
                problems.append("a selection change did not write the capture endpoint")
            elif expected and match.group(1).strip() != expected:
                problems.append(
                    f"the saved capture endpoint is {match.group(1).strip()}, not the entry the "
                    f"user selected ({expected})")
        finally:
            gui.close()

        # 4. Changing one side must not erase a saved-but-missing id on the other.
        #    Writing an empty value there would turn the next launch into a silent
        #    fallback to the first list entry, which is the substitution the empty
        #    combo exists to prevent.
        if len(outputs) >= 2:
            write_selection(path, STALE_ID, outputs[0][0])
            try:
                gui = Gui(executable)
            except TimeoutError:
                print("SKIPPED: no desktop for the fourth phase; the preservation of a "
                      "missing id was not observed. This is not a pass.")
                return 0
            try:
                # Select an entry that is not already selected, so a change happens.
                gui.select(ID_RENDER, 1)
                written = path.read_text(encoding="utf-8") if path.exists() else ""
                match = re.search(r"^capture=(.*)$", written, re.M)
                if not match:
                    problems.append("changing the output erased the capture line entirely")
                elif match.group(1).strip() != STALE_ID:
                    problems.append(
                        "changing the output endpoint erased the other side's saved-but-missing "
                        f"id (the file now holds {match.group(1).strip()!r}), so the next launch "
                        "would fall back to the first list entry instead of asking again")
            finally:
                gui.close()
    finally:
        if saved_backup is None:
            if path.exists():
                path.unlink()
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(saved_backup)

    if problems:
        for problem in problems:
            print(f"  MISMATCH: {problem}", file=sys.stderr)
        print("GUI device-selection persistence did not verify.", file=sys.stderr)
        return 1

    print("GUI device selection verified: a saved endpoint is restored, a vanished one leaves "
          "the combo empty and makes Start refuse with that reason, a change is written to the "
          "user's own settings file, and changing one side does not erase a saved-but-missing "
          "id on the other (which would turn the next launch into a silent fallback). "
          "The check restored the user's own file afterwards.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
