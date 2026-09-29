#!/usr/bin/env python3
"""Draw on the running bin/paint window with XTEST synthetic input and
verify the stroke landed on the canvas."""
import ctypes
import subprocess
import time

x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
xtst = ctypes.cdll.LoadLibrary("libXtst.so.6")
x11.XOpenDisplay.restype = ctypes.c_void_p
DPY = x11.XOpenDisplay(None)


def find_window(title):
    tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
    for line in tree.splitlines():
        if title in line:
            wid = int(line.strip().split(None, 1)[0], 16)
            return wid
    return None


def motion(x, y):
    xtst.XTestFakeMotionEvent(DPY, 0, x, y, 0)
    x11.XFlush(DPY)


def button(down, which=1):
    xtst.XTestFakeButtonEvent(DPY, which, down, 0)
    x11.XFlush(DPY)


def main():
    wid = find_window("Paint")
    assert wid, "no Paint window"
    info = subprocess.check_output(["xwininfo", "-id", str(wid)], text=True)
    gx = gy = None
    for line in info.splitlines():
        if "Absolute upper-left X" in line:
            gx = int(line.split(":")[1])
        if "Absolute upper-left Y" in line:
            gy = int(line.split(":")[1])
    print(f"win {wid} at +{gx}+{gy}")

    def path(points, hold=True):
        for i, (x, y) in enumerate(points):
            motion(gx + x, gy + y)
            time.sleep(0.03)
            if hold and i == 0:
                button(True)

    # pencil stroke: two segments
    path([(200, 200), (300, 260), (250, 350)])
    button(False)
    time.sleep(0.4)
    subprocess.run(["import", "-window", str(wid), "/tmp/paint_draw.png"], check=True)

    from PIL import Image
    im = Image.open("/tmp/paint_draw.png").convert("RGB")
    seg1 = sum(1 for t in [i / 20 for i in range(21)]
               if im.getpixel((int(200 + 100 * t), int(200 + 60 * t))) == (0, 0, 0))
    seg2 = sum(1 for t in [i / 20 for i in range(21)]
               if im.getpixel((int(300 - 50 * t), int(260 + 90 * t))) == (0, 0, 0))
    print(f"stroke seg1 black: {seg1}/21  seg2: {seg2}/21")
    assert seg1 > 15 and seg2 > 15, "pencil stroke missing"
    print("PENCIL OK")


if __name__ == "__main__":
    main()


def shape_test():
    """Switch to the Rectangle tool (toolbox index 12, row 6 col 0) and
    drag a rectangle on the canvas."""
    wid = find_window("Paint")
    assert wid
    info = subprocess.check_output(["xwininfo", "-id", str(wid)], text=True)
    gx = gy = None
    for line in info.splitlines():
        if "Absolute upper-left X" in line:
            gx = int(line.split(":")[1])
        if "Absolute upper-left Y" in line:
            gy = int(line.split(":")[1])
    # toolbox cells start at (3, 3) inside the side panel, which starts
    # below the menu bar. Probe by scanning for the silver cell grid is
    # overkill — the menu bar is ~19px tall under the ~28px caption.
    tool_y = gy + 28 + 20 + 3 + 6 * 26 + 12
    tool_x = gx + 3 + 12
    path([(tool_x - gx, tool_y - gy)], hold=False)  # motion helper uses gx/gy of main(); write directly:
    motion(tool_x, tool_y)
    time.sleep(0.1)
    button(True); time.sleep(0.05); button(False)
    time.sleep(0.3)
    subprocess.run(["import", "-window", str(wid), "/tmp/paint_rect_tool.png"], check=True)
    from PIL import Image
    im = Image.open("/tmp/paint_rect_tool.png").convert("RGB")
    # selected cell: sunken + SEL_BG fill (182,186,199)
    px = im.getpixel((tool_x - gx, tool_y - gy))
    print("tool cell px:", px)
    # drag an ellipse... rect: from (150,150) to (400,300)
    motion(gx + 150, gy + 150); time.sleep(0.05)
    button(True)
    for i in range(11):
        motion(gx + 150 + 25 * i, gy + 150 + 15 * i)
        time.sleep(0.02)
    button(False)
    time.sleep(0.4)
    subprocess.run(["import", "-window", str(wid), "/tmp/paint_rect.png"], check=True)
    im2 = Image.open("/tmp/paint_rect.png").convert("RGB")
    edge_top = sum(1 for x in range(150, 400, 10)
                   if im2.getpixel((x, 150)) == (0, 0, 0))
    edge_bottom = sum(1 for x in range(150, 400, 10)
                      if im2.getpixel((x, 299)) == (0, 0, 0))
    print(f"rect top {edge_top}/25 bottom {edge_bottom}/25")
    assert edge_top > 20 and edge_bottom > 20, "rectangle missing"
    print("RECT OK")
