#!/usr/bin/env python3
"""Pixel oracle for bin/apps/notepad with the File menu OPEN — the
state the BACKEND=vulkan text regression is visible in.

    python3 scripts/make_notepad_menu_shots.py [binary] [outdir]

Launches the app with NO file arguments (the welcome tab's caret sits
top-left of the editor, exactly under the File popup, so the captured
state is fully static), XTEST-clicks the «File» menu-bar button at
fixed client coordinates, waits out the popup appear animation, and
captures the window with xwd + ImageMagick:

  notepad-menu-open.png   File menu open (menu items New/Open…/Save…/
                          Save As…/Close Tab/Quit with hotkey hints)

Geometry (client-space, window 800x600 borderless): the caption strip
carries the tabs (TitleBarTabs::CAPTION_H = 44), the menu bar starts
right below; «File» is the first button, its text ~16px in — the click
at (20, 60) lands mid-button. Any layout change that moves the button
invalidates the click point (recheck against a shot).

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
xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                      ctypes.c_int, ctypes.c_int,
                                      ctypes.c_ulong]
xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                      ctypes.c_int, ctypes.c_ulong]

DPY = x11.XOpenDisplay(None)
if not DPY:
    sys.exit("cannot open X display")

TITLE = "egui-cr — notepad"

# «File» in client space: caption 44px, menu bar below, first button.
FILE_X, FILE_Y = 20, 60

# _NET_WM_PID of a client window (0 when absent): the driver must drive
# and capture ONLY the app it launched — a same-titled window left from
# an earlier run (or the user's own) would otherwise steal the clicks
# and end up in the shot.
x11.XGetWindowProperty.restype = ctypes.c_int
x11.XGetWindowProperty.argtypes = [
    ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
    ctypes.c_long, ctypes.c_long, ctypes.c_int, ctypes.c_ulong,
    ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_void_p)]
x11.XFree.argtypes = [ctypes.c_void_p]
_NET_WM_PID = 341


def window_pid(wid: int) -> int:
    actual_type = ctypes.c_ulong()
    actual_format = ctypes.c_int()
    nitems = ctypes.c_ulong()
    bytes_after = ctypes.c_ulong()
    data = ctypes.c_void_p()
    if x11.XGetWindowProperty(DPY, wid, _NET_WM_PID, 0, 1, 0, 6,
                              ctypes.byref(actual_type),
                              ctypes.byref(actual_format),
                              ctypes.byref(nitems),
                              ctypes.byref(bytes_after),
                              ctypes.byref(data)) != 0 or nitems.value != 1:
        return 0
    pid = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))[0]
    x11.XFree(data)
    return pid


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


def wait_window(before: set[int], pid: int,
                timeout: float = 15.0) -> tuple[int, tuple[int, int]]:
    """The launched app's window id + absolute position: a NEW titled
    window that was not live at launch (stale same-titled windows from
    earlier runs must not steal the session), preferring an exact
    _NET_WM_PID == pid match."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for wid in find_windows():
            if wid in before:
                continue
            if window_pid(wid) in (0, pid):
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
    actually holds the focus afterwards (synthetic input goes ONLY
    then — never into whatever the user had focused)."""
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


def main() -> None:
    binary = sys.argv[1] if len(sys.argv) > 1 else "bin/apps/notepad"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "oracle/menu-shots"
    os.makedirs(outdir, exist_ok=True)

    app = subprocess.Popen([binary])
    try:
        before = set(find_windows())
        wid, (wx, wy) = wait_window(before, app.pid)
        time.sleep(1.0)  # chrome + first layout settle
        if not focus_window(wid):
            sys.exit("window did not take focus — not clicking blind")
        # File menu open: click, let the appear animation finish, grab.
        click(wx + FILE_X, wy + FILE_Y)
        time.sleep(1.2)
        # Refind ONLY our window: the confirm-modal case can re-map it,
        # but a user's same-titled window must never end up in the shot.
        live = [w for w in find_windows()
                if w not in before and window_pid(w) in (0, app.pid)]
        capture(live[-1] if live else wid,
                os.path.join(outdir, "notepad-menu-open.png"))
    finally:
        app.terminate()
        try:
            app.wait(timeout=3)
        except subprocess.TimeoutExpired:
            app.kill()
        time.sleep(0.6)  # let the WM unmap the window


if __name__ == "__main__":
    main()
