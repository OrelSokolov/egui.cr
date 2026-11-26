#!/usr/bin/env python3
"""Overlay native vs egui scroll-oracle recordings as HTML charts.

Usage:
    python3 scripts/compare_scroll.py                      # both defaults
    python3 scripts/compare_scroll.py a.json b.json out.html

Each recording (tmp/scroll_native.json, tmp/scroll_egui.json) holds the
touchpad event stream and offset samples on one monotonic clock. Time
is re-based to the first event of each capture so two separately taken
sessions overlay; the charts show where the offset curves diverge.
Output is a dependency-free HTML file with inline SVG.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.join(HERE, "..", "tmp")
DEFAULTS = [
    ("native", os.path.join(TMP, "scroll_native.json"), "#0072c4"),
    ("egui", os.path.join(TMP, "scroll_egui.json"), "#d4370f"),
]


def load(path):
    with open(path) as f:
        d = json.load(f)
    ev = d.get("events", [])
    off = d.get("offsets", [])
    if not ev and not off:
        return None
    # rebase + filter: an egui capture mixes injected (replay schedule)
    # and real touchpad events; only the injected stream aligns with
    # the native oracle, so keep inj==1 when the marker exists.
    if any(e.get("inj") for e in ev):
        ev = [e for e in ev if e.get("inj") == 1]
    if not ev and not off:
        return None
    # re-base to the FIRST EVENT (not the first offset sample): the
    # recording starts at Record/Play, but the gesture begins seconds
    # later — offset-anchored t=0 shifts the curves by that lead-in and
    # the overlay never lines up. Offset samples before the first
    # event are pre-roll and cropped.
    if ev:
        base = min(e["t"] for e in ev)
        off = [o for o in off if o["t"] >= base]
    else:
        base = min(o["t"] for o in off)
    return {
        "app": d.get("app", "?"),
        "events": [{"t": e["t"] - base, "sy": e["sy"], "sx": e.get("sx", 0.0),
                    "momentum": e.get("momentum", 0)} for e in ev],
        "offsets": [{"t": o["t"] - base, "y": o["y"]} for o in off],
    }


def svg_path(points, w, h, color, ymin, ymax, tmax):
    if not points:
        return ""
    span = max(ymax - ymin, 1e-6)
    out = []
    for i in range(1, len(points)):
        x0 = points[i - 1][0] / tmax * w
        x1 = points[i][0] / tmax * w
        y0 = h - (points[i - 1][1] - ymin) / span * h
        y1 = h - (points[i][1] - ymin) / span * h
        out.append(f'<line x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" '
                   f'y2="{y1:.1f}" stroke="{color}" stroke-width="1.5"/>')
    return "".join(out)


def bar_series(events, dt):
    """events/sec histogram + per-event deltas, aligned on one grid."""
    if not events:
        return [], []
    tmax = events[-1]["t"]
    n = max(int(tmax / dt) + 1, 1)
    rate = [0] * n
    for e in events:
        i = min(int(e["t"] / dt), n - 1)
        rate[i] += 1
    return rate, events


def chart_offset(recs, w=960, h=300):
    ys = [o["y"] for (r, _, _) in recs for o in r["offsets"]] or [0.0]
    tmax = max([o["t"] for (r, _, _) in recs for o in r["offsets"]] or [1.0]) * 1.02
    ymin, ymax = min(ys), max(ys)
    pad = max((ymax - ymin) * 0.05, 1.0)
    ymin, ymax = ymin - pad, ymax + pad
    body = "".join(
        svg_path([(o["t"], o["y"]) for o in r["offsets"]], w, h, c, ymin, ymax, tmax)
        for r, _, c in recs)
    # time cells: fixed 100 ms — the user's preferred lag measuring unit
    step = 0.1
    grid = []
    t = 0.0
    while t <= tmax:
        x = t / tmax * w
        grid.append(f'<line x1="{x:.1f}" y1="0" x2="{x:.1f}" y2="{h}" '
                    f'stroke="#e4e4e4"/>')
        grid.append(f'<text x="{x:.1f}" y="{h+14}" font-size="10" '
                    f'fill="#666" text-anchor="middle">'
                    f'{t*1000:.0f}ms</text>')
        t += step
    # horizontal cells with px labels
    ystep = (ymax - ymin) / 6
    for i in range(7):
        y = h - (ymin + i * ystep - ymin) / (ymax - ymin) * h
        grid.append(f'<line x1="0" y1="{y:.1f}" x2="{w}" y2="{y:.1f}" '
                    f'stroke="#e4e4e4"/>')
        grid.append(f'<text x="4" y="{y-3:.1f}" font-size="10" fill="#666">'
                    f'{ymin + i * ystep:.0f}px</text>')
    return f'''<h2>Offset vs time (cells: {step*1000:.0f} ms × {ystep:.0f} px)</h2>
<svg width="{w}" height="{h+22}" style="border:1px solid #999;background:#fff">
{grid}{body}</svg>
<p>x cells: {step*1000:.0f} ms, y cells: {ystep:.0f} px, t range: 0 … {tmax:.2f} s</p>'''


def chart_events(recs, w=960, h=220):
    rows = []
    for r, name, c in recs:
        marks = "".join(
            f'<line x1="{e["t"]*100:.1f}" y1="0" x2="{e["t"]*100:.1f}" '
            f'y2="{h}" stroke="{c}" stroke-opacity="0.6"/>'
            for e in r["events"])
        rows.append(f'<h3 style="color:{c}">{r["app"]}: '
                    f'{len(r["events"])} events</h3>'
                    f'<svg width="{w}" height="{h}" '
                    f'style="border:1px solid #999;background:#fafafa">'
                    f'{marks}</svg>')
    return '<h2>Event ticks (1 px = 10 ms)</h2>' + "".join(rows)


def main():
    args = sys.argv[1:]
    out = os.path.join(TMP, "scroll_compare.html")
    if len(args) >= 3:
        pairs = [("a", args[0], "#0072c4"), ("b", args[1], "#d4370f")]
        out = args[2]
    else:
        pairs = DEFAULTS
    recs = []
    for name, path, color in pairs:
        if os.path.exists(path):
            d = load(path)
            if d:
                d["app"] = name if d["app"] == "?" else d["app"]
                recs.append((d, name, color))
            else:
                print(f"{path}: empty capture, skipped")
        else:
            print(f"{path}: not found, skipped")
    if not recs:
        print("nothing to compare — record both sessions first")
        return 1
    html = (f'<!doctype html><meta charset="utf-8">'
            f'<title>scroll oracle compare</title>'
            f'<body style="font-family:sans-serif;margin:16px">'
            + chart_offset(recs) + chart_events(recs)
            + "</body>")
    with open(out, "w") as f:
        f.write(html)
    print(f"written {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
