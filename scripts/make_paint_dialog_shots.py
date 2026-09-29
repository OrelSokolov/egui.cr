#!/usr/bin/env python3
"""Paint dialog screenshots: find the menu row + item x positions from a
screenshot, click Image → Attributes… and Help → About Paint…, capture.

    python3 scripts/make_paint_dialog_shots.py [outdir]
"""
import os
import re
import subprocess
import sys
import time

import ctypes
from PIL import Image

x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
xtst = ctypes.cdll.LoadLibrary("libXtst.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                               ctypes.c_int, ctypes.c_ulong]
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

TITLE = "untitled - Paint"


def key(keysym, press):
    xtst.XTestFakeKeyEvent(DPY, x11.XKeysymToKeycode(DPY, keysym),
                           1 if press else 0, 0)
    x11.XFlush(DPY)


def esc():
    key(0xFF1B, True)
    key(0xFF1B, False)
    time.sleep(0.3)


def click(x, y, delay=0.4):
    xtst.XTestFakeMotionEvent(DPY, -1, int(x), int(y), 0)
    x11.XFlush(DPY)
    time.sleep(0.1)
    xtst.XTestFakeButtonEvent(DPY, 1, 1, 0)
    x11.XFlush(DPY)
    time.sleep(0.06)
    xtst.XTestFakeButtonEvent(DPY, 1, 0, 0)
    x11.XFlush(DPY)
    time.sleep(delay)


def find_windows():
    try:
        tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
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
        if subprocess.run(["xwininfo", "-id", str(wid)],
                          capture_output=True).returncode == 0:
            ids.append(wid)
    return ids


def wait_window(timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if (ids := find_windows()):
            wid = ids[-1]
            info = subprocess.check_output(["xwininfo", "-id", str(wid)], text=True)
            geo = dict(re.findall(r"(Absolute upper-left [XY]):\s+(\d+)", info))
            if geo:
                return wid, (int(geo["Absolute upper-left X"]),
                             int(geo["Absolute upper-left Y"]))
        time.sleep(0.2)
    sys.exit("paint window never appeared")


def capture(wid, out):
    subprocess.run(["xwd", "-id", str(wid), "-silent", "-out", "/tmp/shot.xwd"],
                   check=True)
    subprocess.run(["convert", "/tmp/shot.xwd", out], check=True)
    print(f"wrote {out}")


def dark_clusters(img, wx, wy, y, x0=0, x1=600):
    """x clusters of dark (text) pixels on row y of the window."""
    cols = [x for x in range(x0, min(x1, img.size[0]))
            if all(c < 100 for c in img.getpixel((x, y)))]
    clusters = []
    for x in cols:
        if clusters and x - clusters[-1][-1] <= 2:
            clusters[-1].append(x)
        else:
            clusters.append([x])
    return [(c[0], c[-1]) for c in clusters if len(c) >= 2]


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "screenshots"
    os.makedirs(outdir, exist_ok=True)
    app = subprocess.Popen(["bin/paint"])
    try:
        wid, (wx, wy) = wait_window()
        time.sleep(1.0)
        x11.XRaiseWindow(DPY, wid)
        x11.XSetInputFocus(DPY, wid, 1, 0)
        x11.XFlush(DPY)
        time.sleep(0.4)
        def word_clusters(im, y):
            chars = dark_clusters(im, wx, wy, y)
            words = []
            for lo, hi in chars:
                if words and lo - words[-1][1] <= 15:
                    words[-1][1] = hi
                else:
                    words.append([lo, hi])
            return [tuple(w) for w in words]

        img = None
        best_y, clusters = 0, []
        for _ in range(10):  # wait until the menu bar text shows up
            capture(wid, os.path.join(outdir, "paint-idle.png"))
            img = Image.open(os.path.join(outdir, "paint-idle.png")).convert("RGB")
            for y in range(16, 130):
                ws = word_clusters(img, y)
                if len(ws) == 6:
                    best_y, clusters = y, ws
                    break
            if clusters:
                break
            time.sleep(0.5)
        if not clusters:
            sys.exit("menu labels not found")
        print("menu text row at", best_y, "labels:", clusters)
        labels = ["File", "Edit", "View", "Image", "Colors", "Help"]
        menus = dict(zip(labels, clusters))

        def dialog_open(im):
            return sum(1 for y in range(0, im.size[1], 4)
                       for x in range(0, im.size[0], 4)
                       if im.getpixel((x, y)) == (248, 246, 231)) > 400

        def open_dialog(menu, name):
            lo, hi = menus[menu]
            mx = wx + (lo + hi) / 2
            for gy in range(best_y + 20, best_y + 320, 7):
                # (re)open the menu, then click the candidate row
                click(mx, wy + best_y, 0.5)
                click(mx, wy + gy, 1.0)
                live = find_windows()
                capture(live[-1] if live else wid, f"/tmp/{name}-try.png")
                im = Image.open(f"/tmp/{name}-try.png").convert("RGB")
                if dialog_open(im):
                    import shutil
                    shutil.copy(f"/tmp/{name}-try.png",
                                os.path.join(outdir, f"paint-{name}.png"))
                    print(f"{name}: dialog opened via row {gy}")
                    esc()
                    time.sleep(0.4)
                    return
                esc()
                time.sleep(0.3)
            print(f"{name}: no dialog opened")

        open_dialog("Image", "attributes")
        open_dialog("Help", "about")
    finally:
        app.terminate()
        try:
            app.wait(timeout=3)
        except subprocess.TimeoutExpired:
            app.kill()


if __name__ == "__main__":
    main()
