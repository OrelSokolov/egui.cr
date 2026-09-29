#!/usr/bin/env python3
"""Demo screenshots for bin/notepad — one image per routed app state.

Launches the app per state, brings up the window, optionally drives it
with synthetic XTEST input (type + Ctrl+W to open the unsaved-changes
modal page), and captures the window with xwd + ImageMagick.

    python3 scripts/make_notepad_screenshots.py [outdir]

States (the router's deep links — same mechanism a future headless
screenshot runner will use):
  root/root            the editor (this README open as the tab content)
  root/settings        the full-window settings page
  root/settings#search settings with the caret in the search field
  root/confirm-close   the unsaved-changes modal page (a typed edit,
                       then Ctrl+W)

Linux/X11 only (DISPLAY required); needs xwininfo, xwd, convert.
"""

import os
import re
import subprocess
import sys
import time

import ctypes

x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
xtst = ctypes.cdll.LoadLibrary("libXtst.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                               ctypes.c_int, ctypes.c_ulong]
x11.XGetInputFocus.argtypes = [ctypes.c_void_p,
                               ctypes.POINTER(ctypes.c_ulong),
                               ctypes.POINTER(ctypes.c_int)]
xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                   ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                      ctypes.c_int, ctypes.c_int,
                                      ctypes.c_ulong]
xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                      ctypes.c_int, ctypes.c_ulong]

DPY = x11.XOpenDisplay(None)
if not DPY:
    sys.exit("cannot open X display")

TITLE = "egui-cr — notepad"
CTRL = 0xFFE3        # Control_L keysym


def key(keysym: int, press: bool) -> None:
    xtst.XTestFakeKeyEvent(DPY, x11.XKeysymToKeycode(DPY, keysym),
                           1 if press else 0, 0)
    x11.XFlush(DPY)


def type_text(text: str) -> None:
    """Lowercase text + punctuation into the focused widget."""
    for ch in text:
        ks = ord(ch)
        if ks < 0x20 or ks > 0x7E:
            continue
        key(ks, True)
        key(ks, False)
        time.sleep(0.03)


def ctrl_key(keysym: int) -> None:
    key(CTRL, True)
    key(keysym, True)
    key(keysym, False)
    key(CTRL, False)
    x11.XFlush(DPY)


def click(x: int, y: int) -> None:
    xtst.XTestFakeMotionEvent(DPY, -1, x, y, 0)
    xtst.XTestFakeButtonEvent(DPY, 1, 1, 0)
    x11.XFlush(DPY)
    xtst.XTestFakeButtonEvent(DPY, 1, 0, 0)
    x11.XFlush(DPY)


def find_windows() -> list[int]:
    """All live window ids carrying the app title."""
    try:
        tree = subprocess.check_output(
            ["xwininfo", "-root", "-tree"], text=True)
    except subprocess.CalledProcessError:
        return []
    ids = []
    for line in tree.splitlines():
        if TITLE not in line:
            continue
        try:
            wid = int(line.strip().split(None, 1)[0], 16)
        except ValueError:
            continue
        # skip entries that vanished between the tree dump and now
        if subprocess.run(["xwininfo", "-id", str(wid)],
                          capture_output=True).returncode == 0:
            ids.append(wid)
    return ids


def wait_window(timeout: float = 15.0) -> tuple[int, tuple[int, int]]:
    """The app's top-level window id + absolute position."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if (ids := find_windows()):
            # Several entries can carry the title (the window itself
            # plus a WM frame listing it) — they nest, so the LAST is
            # the innermost, the actual app window.
            wid = ids[-1]
            info = subprocess.check_output(
                ["xwininfo", "-id", str(wid)], text=True)
            geo = dict(re.findall(r"(Absolute upper-left [XY]):\s+(\d+)", info))
            if geo:
                return wid, (int(geo["Absolute upper-left X"]),
                             int(geo["Absolute upper-left Y"]))
        time.sleep(0.2)
    sys.exit("notepad window never appeared")


def focus_window(wid: int) -> bool:
    """Raise the app window and give it keyboard focus; True if it
    actually holds the focus afterwards (synthetic keys go ONLY then —
    never type into whatever the user had focused)."""
    x11.XRaiseWindow(DPY, wid)
    x11.XSetInputFocus(DPY, wid, 1, 0)  # RevertToPointerRoot, CurrentTime
    x11.XFlush(DPY)
    time.sleep(0.3)
    focused = ctypes.c_ulong()
    revert = ctypes.c_int()
    x11.XGetInputFocus(DPY, ctypes.byref(focused), ctypes.byref(revert))
    return focused.value == wid


def capture(wid: int, out: str) -> None:
    subprocess.run(["xwd", "-id", str(wid), "-silent", "-out", "/tmp/shot.xwd"],
                   check=True)
    subprocess.run(["convert", "/tmp/shot.xwd", out], check=True)
    print(f"wrote {out}")


def run_state(name: str, args: list[str], outdir: str,
              keys: str | None = None, after: list[str] | None = None,
              settle: float = 0.8) -> str:
    """Launch, (optionally) drive, capture one app state."""
    app = subprocess.Popen(["bin/notepad", *args])
    try:
        wid, (wx, wy) = wait_window()
        time.sleep(settle)
        # Synthetic input only ever goes to the app's own window: it
        # must hold the keyboard focus first.
        armed = focus_window(wid)
        if not armed:
            print(f"[{name}] warning: window did not take focus — "
                  "skipping input, capturing as-is")
        if armed and keys:
            type_text(keys)
            time.sleep(0.3)
        for combo in (after or []) if armed else []:
            ctrl_key(ord(combo))
            time.sleep(0.5)
        # the window may have changed (confirm modal etc.) — refind it
        live = find_windows()
        out = os.path.join(outdir, f"notepad-{name}.png")
        capture(live[-1] if live else wid, out)
        return out
    finally:
        app.terminate()
        try:
            app.wait(timeout=3)
        except subprocess.TimeoutExpired:
            app.kill()
        time.sleep(0.6)  # let the WM unmap the window before the next run


def main() -> None:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "screenshots"
    os.makedirs(outdir, exist_ok=True)
    doc = "README.md"

    # root/root — the editor, this README open as the tab.
    run_state("root", [doc], outdir)
    # root/settings — the full-window settings page (deep link).
    run_state("settings", ["--page", "root/settings", doc], outdir)
    # root/settings#search — same page, caret in the search field. The
    # caret blinks (60% duty cycle) — take two frames, keep the one
    # where it shows.
    run_state("settings-focus", ["--page", "root/settings#search", doc],
              outdir, settle=1.0)
    # root/confirm-close — a typed edit makes the tab dirty, Ctrl+W
    # then opens the unsaved-changes modal PAGE over the editor.
    run_state("confirm-close", [doc], outdir,
              keys="demo edit", after=["w"], settle=1.0)


if __name__ == "__main__":
    main()
