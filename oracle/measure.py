#!/usr/bin/env python3
"""Measure the GTK/Qt widget oracle sheets (oracle/<gtk|qt>/png).

Prints a readable report: per sheet the widget bboxes (column 1 =
x<200), the dominant fill colors inside each widget, edge/border
colors, and corner-rounding estimates. Feeds oracle/FINDINGS.md and
the GnomeTheme/KdeTheme values.
"""

import sys
from collections import Counter
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent


def bbox(im, bg, x0, x1, y0, y1):
    xs, ys = [], []
    for y in range(y0, y1):
        for x in range(x0, x1):
            if im.getpixel((x, y)) != bg:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def colors_in(im, box, bg, top=4):
    c = Counter()
    x0, y0, x1, y1 = box
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            p = im.getpixel((x, y))
            if p != bg:
                c[p] += 1
    return c.most_common(top)


def rounding_at(im, box, fill, tol=40):
    """Estimate the corner radius of the top-left corner: first row y0
    where the fill appears, vs. the box's left edge."""
    x0, y0, x1, y1 = box

    def near(a, b):
        return sum(abs(a[i] - b[i]) for i in range(3)) <= tol

    # walk down the left edge; the first y where pixels at x0 are fill
    for dy in range(0, y1 - y0):
        if any(near(im.getpixel((x0 + dx, y0 + dy)), fill) for dx in range(3)):
            return dy
    return -1


def measure(kind):
    bg = (250, 250, 250) if kind == "gtk" else (239, 239, 239)
    d = HERE / kind / "png"
    print(f"===== {kind.upper()} =====  sheet bg {bg}")
    for f in sorted(d.glob("*.png")):
        im = Image.open(f).convert("RGB")
        name = f.stem
        col1 = bbox(im, bg, 0, 200, 0, 160)
        col2 = bbox(im, bg, 200, 480, 0, 160)
        line = [f"{name}:"]
        for tag, box in (("c1", col1), ("c2", col2)):
            if not box:
                continue
            x0, y0, x1, y1 = box
            line.append(f"{tag}=[{x0},{y0}..{x1},{y1}] {x1-x0+1}x{y1-y0+1}")
        print(" ".join(line))
        for tag, box in (("c1", col1), ("c2", col2)):
            if not box:
                continue
            cols = colors_in(im, box, bg)
            if cols:
                print(f"  {tag} colors: " +
                      ", ".join(f"#{c[0]:02X}{c[1]:02X}{c[2]:02X}x{n}"
                                for c, n in cols))
        if col1:
            fills = colors_in(im, col1, bg, top=1)
            if fills:
                r = rounding_at(im, col1, fills[0][0])
                print(f"  c1 top-left rounding ≈ {r}px")


if __name__ == "__main__":
    for kind in (sys.argv[1:] or ["gtk", "qt"]):
        measure(kind)
