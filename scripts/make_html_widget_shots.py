#!/usr/bin/env python3
"""html_gallery widget shots for the twinshot `backends` group.

One PNG per widget card: launch `bin/html/html_gallery --only <needle>`
with PAUSE=1 (frozen frame time — animated cards like «heading scale»
paint a static frame, any two captures are identical), settle out the
async canvas2d bakes, grab the window with xwd + ImageMagick, kill.

Why xwd and not the app's own `--screenshot`: that path is a GL
readback (backend/sokol_shim.c sh_screenshot_try) which stays pending
forever under BACKEND=vulkan — the external grab is the only capture
that works on BOTH backends, and both legs of the `backends` group use
it, so the comparison stays 1:1.

    python3 scripts/make_html_widget_shots.py [binary] [outdir]

The widget list is shared with the `html` (SDF parity) group — imported
from make_html_sdf_shots, never duplicated.

Linux/X11 only (DISPLAY required); needs xwininfo, xwd, convert.
"""

import os
import re
import subprocess
import sys
import time

import ctypes

x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

DPY = x11.XOpenDisplay(None)
if not DPY:
    sys.exit("cannot open X display")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_html_sdf_shots import WIDGETS  # noqa: E402
from make_notepad_menu_shots import window_pid  # noqa: E402

TITLE = "egui.cr — html gallery"

# 3.5 s settle: the canvas2d gradient cards bake async (the SDF group's
# 1 s caught unbaked canvases under load); PAUSE=1 holds the frame.
SETTLE = 3.5


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


def wait_new_window(before: set[int], pid: int,
                    timeout: float = 15.0) -> int:
    """The launched app's window: a NEW titled window not live at
    launch, preferring an exact _NET_WM_PID == pid match — a user's or
    a stale same-titled window must never end up in the shot."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for wid in find_windows():
            if wid in before:
                continue
            if window_pid(wid) in (0, pid):
                return wid
        time.sleep(0.2)
    sys.exit("html gallery window never appeared")


def capture(wid: int, out: str) -> None:
    subprocess.run(["xwd", "-id", str(wid), "-silent", "-out", "/tmp/shot.xwd"],
                   check=True)
    subprocess.run(["convert", "/tmp/shot.xwd", out], check=True)
    print(f"wrote {out}")


def main() -> None:
    binary = sys.argv[1] if len(sys.argv) > 1 else "bin/html/html_gallery"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "oracle/backends-shots"
    os.makedirs(outdir, exist_ok=True)
    env = dict(os.environ, PAUSE="1")

    for needle, slug in WIDGETS:
        app = subprocess.Popen([binary, "--only", needle], env=env)
        try:
            before = set(find_windows())
            wid = wait_new_window(before, app.pid)
            x11.XRaiseWindow(DPY, wid)
            x11.XFlush(DPY)
            time.sleep(SETTLE)
            live = [w for w in find_windows()
                    if w not in before and window_pid(w) in (0, app.pid)]
            capture(live[-1] if live else wid,
                    os.path.join(outdir, f"{slug}.png"))
        finally:
            app.terminate()
            try:
                app.wait(timeout=3)
            except subprocess.TimeoutExpired:
                app.kill()
            time.sleep(0.6)  # let the WM unmap the window
    print(f"done: {len(WIDGETS)} shots → {outdir}")


if __name__ == "__main__":
    main()
