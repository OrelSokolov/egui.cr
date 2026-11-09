#!/usr/bin/env python3
"""Pixel-diff the native oracle sheets against the egui.cr twins.

The same metric as the macOS oracle rounds (oracle/FINDINGS.md): the
share of pixels differing beyond a small per-channel tolerance (pure
antialiasing shifts shouldn't count).

  python3 oracle/diff_sheets.py gnome     # gtk/png vs egui-gnome/png
  python3 oracle/diff_sheets.py kde       # qt/png  vs egui-kde/png
  python3 oracle/diff_sheets.py gnome kde --diff   # write diff images
"""

import sys
from pathlib import Path

from PIL import Image, ImageChops

HERE = Path(__file__).resolve().parent
PAIRS = {
    "gnome": ("gtk", "egui-gnome"),
    "kde": ("qt", "egui-kde"),
}
TOL = 16  # per-channel slack: AA edges survive, color/geometry doesn't


def diff_sheet(native: Path, twin: Path, out=None):
    a = Image.open(native).convert("RGB")
    b = Image.open(twin).convert("RGB")
    if a.size != b.size:
        b = b.resize(a.size)
    d = ImageChops.difference(a, b)
    px = list(d.getdata())
    bad = sum(1 for p in px if max(p) > TOL)
    ratio = 100.0 * bad / len(px)
    if out:
        # heat image: differing pixels black→red, matching white
        heat = Image.new("RGB", a.size, (255, 255, 255))
        hp = heat.load()
        dp = d.load()
        for y in range(a.size[1]):
            for x in range(a.size[0]):
                p = dp[x, y]
                if max(p) > TOL:
                    hp[x, y] = (255, 0, 0)
        heat.save(out)
    return ratio


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    want_diff = "--diff" in sys.argv
    kinds = args or list(PAIRS)
    for kind in kinds:
        native_dir, twin_dir = PAIRS[kind]
        print(f"===== {kind}: {native_dir}/png vs {twin_dir}/png =====")
        ratios = []
        for native in sorted((HERE / native_dir / "png").glob("*.png")):
            twin = HERE / twin_dir / "png" / native.name
            if not twin.exists():
                print(f"  {native.stem}: MISSING twin")
                continue
            out = HERE / twin_dir / "diff" / f"{native.stem}.diff.png"
            if want_diff:
                out.parent.mkdir(parents=True, exist_ok=True)
            r = diff_sheet(native, twin, out if want_diff else None)
            ratios.append((native.stem, r))
            print(f"  {native.stem}: {r:.2f}%")
        if ratios:
            avg = sum(r for _, r in ratios) / len(ratios)
            best = min(ratios, key=lambda t: t[1])
            worst = max(ratios, key=lambda t: t[1])
            print(f"  avg {avg:.2f}% | best {best[0]} {best[1]:.2f} | "
                  f"worst {worst[0]} {worst[1]:.2f}")


if __name__ == "__main__":
    main()
