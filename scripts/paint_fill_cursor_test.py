#!/usr/bin/env python3
"""Smoke-drive bin/paint: select the Fill tool, hover the canvas — the
custom bitmap cursor path (egui_cr_set_cursor_image) must run."""
import ctypes
import subprocess
import sys
import time

x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
xtst = ctypes.cdll.LoadLibrary("libXtst.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
DPY = x11.XOpenDisplay(None)


def find_window(title):
    tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
    for line in tree.splitlines():
        if title in line:
            return int(line.strip().split(None, 1)[0], 16)
    return None


def motion(x, y):
    xtst.XTestFakeMotionEvent(DPY, 0, x, y, 0)
    x11.XFlush(DPY)


def button(down, which=1):
    xtst.XTestFakeButtonEvent(DPY, which, down, 0)
    x11.XFlush(DPY)


def main():
    wid = None
    for _ in range(60):
        wid = find_window("Paint")
        if wid:
            break
        time.sleep(0.5)
    assert wid, "no Paint window"
    info = subprocess.check_output(["xwininfo", "-id", str(wid)], text=True)
    gx = gy = None
    for line in info.splitlines():
        if "Absolute upper-left X" in line:
            gx = int(line.split(":")[1])
        if "Absolute upper-left Y" in line:
            gy = int(line.split(":")[1])
    print(f"win {wid} at +{gx}+{gy}")

    # hover the canvas first (pencil → named cursor path)
    motion(gx + 300, gy + 250)
    time.sleep(0.3)
    # click the Fill tool cell (toolbox index 3 — window-relative rect
    # 41..66 × 114..139 at the time of writing; the toolbox layout
    # follows the example, re-measure via the app's interact rects if
    # the click stops landing)
    motion(gx + 53, gy + 126)
    time.sleep(0.2)
    button(True); time.sleep(0.05); button(False)
    time.sleep(0.2)
    # Informational only: SEL_BG at the cell means selected+hovered. The
    # definitive check is outside this script — run bin/paint under
    #   gdb -batch -ex 'break egui_cr_set_cursor_image' -ex run --args bin/paint
    # and drive this same sequence: the breakpoint must hit from
    # paint_frame once the canvas is hovered with Fill active.
    subprocess.run(["import", "-window", str(wid), "/tmp/paint_fill_sel.png"],
                   check=True)
    from PIL import Image
    print("fill cell px (SEL_BG=(182,186,199) if selected+hovered):",
          Image.open("/tmp/paint_fill_sel.png").convert("RGB").getpixel((43, 116)))
    # hover the canvas with Fill active → bitmap cursor requested
    motion(gx + 300, gy + 250)
    time.sleep(0.5)
    alive = subprocess.run(["xwininfo", "-id", str(wid)],
                           capture_output=True).returncode == 0
    print("window alive:", alive)
    subprocess.run(["import", "-window", str(wid), "/tmp/paint_fill_hover.png"],
                   check=True)
    assert alive, "paint window died"
    print("FILL HOVER OK")


if __name__ == "__main__":
    main()
