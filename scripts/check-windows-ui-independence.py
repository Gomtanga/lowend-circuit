"""Verify the DSP and audio engine do not depend on the user interface.

The Windows port keeps the DSP and the audio engine in `lowend_engine`, a static
library that both front ends link. That separation is a stated design guarantee,
and it is the kind of thing that erodes quietly: one `#include` of a GUI header
from the engine, one `HWND` passed through an engine signature, one UI library
added to the engine's link line.

Building with the GUI target switched off catches only the last of those, because
the GUI sources stay on disk either way - a header include still resolves. So this
script checks all three layers directly:

  1. engine sources reference no UI header, no UI symbol, no GUI source
  2. the engine target links no UI library
  3. the GUI sources contain no DSP or device implementation of their own

It runs without a compiler or an audio device, so CI can run it on any runner.

Usage:  python scripts/check-windows-ui-independence.py
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
ENGINE = REPO / "Windows" / "Source" / "AudioEngine"
GUI = REPO / "Windows" / "Source" / "GUI"
CMAKE = REPO / "Windows" / "CMakeLists.txt"

# Headers that exist only to build windows and controls. `windows.h` is not here
# on purpose: WASAPI and COM need it, and the engine defines WIN32_LEAN_AND_MEAN.
UI_HEADERS = ("commctrl.h", "windowsx.h", "uxtheme.h", "gdiplus.h", "shellapi.h")

# Win32 user-interface entry points. A window procedure, a control message, or a
# dialog box in the engine would mean the engine can no longer run headless.
UI_SYMBOLS = (
    r"\bHWND\b", r"\bHWND__\b", r"\bCreateWindowExW?\b", r"\bRegisterClassExW?\b",
    r"\bWNDCLASSEXW?\b", r"\bWNDCLASSW?\b", r"\bMessageBoxW?\b", r"\bDialogBox\w*\b",
    r"\bSendMessageW?\b", r"\bPostMessageW?\b", r"\bSetWindowText\w*\b",
    r"\bGetWindowText\w*\b", r"\bWM_[A-Z_]+\b", r"\bDefWindowProcW?\b",
    r"\bGetMessageW?\b", r"\bDispatchMessageW?\b", r"\bPeekMessageW?\b",
    r"\bSetTimer\b", r"\bKillTimer\b", r"\bGetDlgItem\b",
)

# A GUI front end must stay thin: it reads and writes Settings and calls the
# engine. DSP kernels and WASAPI interfaces belong to the engine.
GUI_FORBIDDEN = (
    r"\blowend::Processor\b", r"\blowend::CircuitBass\b", r"\blowend::HighExciter\b",
    r"\blowend::SpatialProcessor\b", r"\bIMMDeviceEnumerator\b", r"\bIAudioClient\b",
    r"\bIAudioCaptureClient\b", r"\bIAudioRenderClient\b", r"\bWasapiCapture\b",
    r"\bWasapiRender\b", r"\bDspStage\b",
)

# Libraries that only exist to draw windows and controls.
UI_LIBS = ("user32", "comctl32", "gdi32", "gdiplus", "uxtheme", "shell32")

# Strip comments and string literals before scanning: a comment that says
# "WASAPI loopback copies..." or a status message containing the word
# "HighExciter" is not a dependency.
#
# Include directives are stripped as a whole. Their quoted path is a string
# literal, so blanking string literals first would erase exactly the `#include`
# lines this script exists to inspect. Includes are handled separately instead.
INCLUDE_RE = re.compile(r"^[ \t]*#[ \t]*include\b[^\n]*", re.M)


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    text = re.sub(r"R\"[^(]*\(.*?\)[^\"]*\"", " ", text, flags=re.S)
    text = re.sub(r"\"(?:[^\"\\\n]|\\.)*\"", '""', text)
    text = re.sub(r"'(?:[^'\\\n]|\\.)*'", "''", text)
    return text


def scan_include_paths(root: pathlib.Path, patterns, label: str) -> list:
    """Scan `#include` directives, which the literal stripper above removes."""
    findings = []
    for path in source_files(root):
        raw = path.read_text(encoding="utf-8")
        for match in INCLUDE_RE.finditer(raw):
            directive = match.group(0)
            for pattern in patterns:
                if re.search(pattern, directive):
                    line = raw[:match.start()].count("\n") + 1
                    findings.append(
                        f"{path.relative_to(REPO)}:{line}: {label} {directive.strip()}")
    return findings


def source_files(root: pathlib.Path):
    return sorted(p for p in root.rglob("*") if p.suffix in (".cpp", ".h"))


def scan(root: pathlib.Path, patterns, label: str) -> list:
    findings = []
    for path in source_files(root):
        code = strip_comments_and_strings(path.read_text(encoding="utf-8"))
        for pattern in patterns:
            for match in re.finditer(pattern, code, re.M):
                line = code[:match.start()].count("\n") + 1
                findings.append(f"{path.relative_to(REPO)}:{line}: {label} {match.group(0)}")
    return findings


def engine_links_ui_libs() -> list:
    """Check the engine target's link line, stopping at the next target."""
    text = CMAKE.read_text(encoding="utf-8")
    match = re.search(r"target_link_libraries\(lowend_engine(.*?)\)", text, re.S)
    if not match:
        return ["Windows/CMakeLists.txt: could not find the lowend_engine link line"]
    body = match.group(1)
    return [f"Windows/CMakeLists.txt: lowend_engine links a UI library: {lib}"
            for lib in UI_LIBS if re.search(rf"\b{lib}\b", body)]


def main() -> None:
    problems = []
    # Engine side: no UI header, no GUI source, and no UI symbol or message id.
    problems += scan_include_paths(
        ENGINE, (r"<(?:%s)>" % "|".join(re.escape(h) for h in UI_HEADERS),
                 r"GUI/", r"ControlPanel\.h", r"MainWindow\.h"),
        "references UI from an include")
    problems += scan(ENGINE, UI_SYMBOLS, "uses UI symbol")
    problems += engine_links_ui_libs()

    # GUI side: it may include engine headers to call the engine, but it must not
    # pull in the DSP kernels or the WASAPI interfaces and use them itself.
    problems += scan_include_paths(
        GUI, (r"Core/Processor\.h", r"Core/CircuitBass\.h", r"Core/HighExciter\.h",
              r"Core/SpatialProcessor\.h", r"AudioEngine/WasapiDevices\.h",
              r"AudioEngine/DspStage\.h"),
        "includes an engine or DSP implementation header")
    problems += scan(GUI, GUI_FORBIDDEN, "implements engine or device code")

    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        print(f"\n{len(problems)} problem(s): the DSP or engine depends on the UI, "
              f"or the GUI reimplements engine/device code.", file=sys.stderr)
        raise SystemExit(1)

    engine_count = len(source_files(ENGINE))
    gui_count = len(source_files(GUI))
    print(f"UI independence verified: {engine_count} engine source file(s) reference no UI "
          f"header, symbol, or GUI source and link no UI library; "
          f"{gui_count} GUI source file(s) contain no DSP or device implementation.")


if __name__ == "__main__":
    main()
