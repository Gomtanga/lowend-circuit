"""Capture a window's client area to a PNG, for visual verification.

Used to check that the Windows GUI actually renders: a process that stays alive
can still be an empty or broken window.

Usage:  python scripts/capture-window.py <title-substring> <output.png>
"""
import ctypes
import ctypes.wintypes as wintypes
import struct
import sys

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

PW_RENDERFULLCONTENT = 0x00000002
SRCCOPY = 0x00CC0020
BI_RGB = 0


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD),
        ("biWidth", wintypes.LONG),
        ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD),
        ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD),
        ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 3)]


def find_window(needle: str):
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
        if needle.lower() in buffer.value.lower():
            found.append((hwnd, buffer.value))
            return False
        return True

    user32.EnumWindows(callback, 0)
    return found[0] if found else (None, None)


def write_png(path: str, width: int, height: int, pixels: bytes) -> None:
    import zlib

    raw = bytearray()
    stride = width * 4
    # The captured buffer is bottom-up BGRA; PNG wants top-down RGBA.
    for y in range(height - 1, -1, -1):
        raw.append(0)  # filter type: none
        row = pixels[y * stride:(y + 1) * stride]
        for x in range(0, stride, 4):
            raw += bytes((row[x + 2], row[x + 1], row[x], 255))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
           + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: capture-window.py <title-substring> <output.png>")
    needle, output = sys.argv[1], sys.argv[2]

    hwnd, title = find_window(needle)
    if hwnd is None:
        raise SystemExit(f"No visible window matching {needle!r}.")

    # PrintWindow renders the whole window, non-client area included. Capturing
    # straight into a client-sized bitmap would shift everything down and clip
    # the bottom, so the full window is captured and then cropped to the client
    # region using the difference between the two rectangles.
    windowRect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(windowRect))
    windowWidth = windowRect.right - windowRect.left
    windowHeight = windowRect.bottom - windowRect.top
    if windowWidth <= 0 or windowHeight <= 0:
        raise SystemExit(f"Window {title!r} has an empty area.")

    clientRect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(clientRect))
    origin = wintypes.POINT(clientRect.left, clientRect.top)
    user32.ClientToScreen(hwnd, ctypes.byref(origin))
    cropX = origin.x - windowRect.left
    cropY = origin.y - windowRect.top
    cropWidth = clientRect.right - clientRect.left
    cropHeight = clientRect.bottom - clientRect.top
    if cropWidth <= 0 or cropHeight <= 0:
        raise SystemExit(f"Window {title!r} has an empty client area.")

    window_dc = user32.GetDC(hwnd)
    memory_dc = gdi32.CreateCompatibleDC(window_dc)
    bitmap = gdi32.CreateCompatibleBitmap(window_dc, windowWidth, windowHeight)
    gdi32.SelectObject(memory_dc, bitmap)

    # PW_RENDERFULLCONTENT makes the common controls and themed parts render
    # into the DC; a plain BitBlt leaves them blank.
    if not user32.PrintWindow(hwnd, memory_dc, PW_RENDERFULLCONTENT):
        gdi32.BitBlt(memory_dc, 0, 0, windowWidth, windowHeight, window_dc, 0, 0, SRCCOPY)

    info = BITMAPINFO()
    info.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    info.bmiHeader.biWidth = windowWidth
    info.bmiHeader.biHeight = windowHeight
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = BI_RGB

    full = ctypes.create_string_buffer(windowWidth * windowHeight * 4)
    gdi32.GetDIBits(memory_dc, bitmap, 0, windowHeight, full, ctypes.byref(info), 0)

    # Crop rows/columns out of the full-window BGRA buffer.
    pixels = bytearray()
    for y in range(cropY, cropY + cropHeight):
        start = (y * windowWidth + cropX) * 4
        pixels += full.raw[start:start + cropWidth * 4]

    write_png(output, cropWidth, cropHeight, bytes(pixels))

    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(memory_dc)
    user32.ReleaseDC(hwnd, window_dc)
    print(f"captured {title!r} client area {cropWidth}x{cropHeight} -> {output}")


if __name__ == "__main__":
    main()
