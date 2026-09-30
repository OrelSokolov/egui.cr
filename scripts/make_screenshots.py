#!/usr/bin/env python3
"""Regenerates every README screenshot into screenshots/.

One script so a new release re-shoots the whole set the same way:

    python3 scripts/make_screenshots.py [--no-build] [outdir]

Shots (apps are driven through their scriptable flags — no mouse
coords are required unless a shot deliberately draws):

  notepad-dark.png / notepad-light.png   the notepad editor (root page)
                                        in both themes (`--theme`)
  frame-windows.png / frame-xp.png /    the borderless demo's four
  frame-ubuntu.png / frame-macos.png    client-side window frames
                                        (`--frame`)
  widgets-dark.png                      the widget gallery, default
                                        dark theme
  widgets-styled.png                    the gallery under a custom
                                        stylesheet theme (`--styled`)
  paint.png                             the paint app with a couple of
                                        synthetic strokes (XTEST drag)

Binaries are built with `rake build:release` first (skip with
--no-build). Linux/X11 only (DISPLAY required); needs xwininfo, xwd,
convert.
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


def find_windows(title: str) -> list[int]:
    """All live window ids carrying the app title."""
    try:
        tree = subprocess.check_output(
            ["xwininfo", "-root", "-tree"], text=True)
    except subprocess.CalledProcessError:
        return []
    ids = []
    for line in tree.splitlines():
        if title not in line:
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


def wait_window(title: str, timeout: float = 20.0) -> int:
    """The app's top-level window id (innermost of the title matches)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if (ids := find_windows(title)):
            return ids[-1]
        time.sleep(0.2)
    sys.exit(f"{title} window never appeared")


def focus_window(wid: int) -> bool:
    """Raise the window and take keyboard focus (input safety)."""
    x11.XRaiseWindow(DPY, wid)
    x11.XSetInputFocus(DPY, wid, 1, 0)
    x11.XFlush(DPY)
    time.sleep(0.3)
    focused = ctypes.c_ulong()
    revert = ctypes.c_int()
    x11.XGetInputFocus(DPY, ctypes.byref(focused), ctypes.byref(revert))
    return focused.value == wid


def motion(x: int, y: int) -> None:
    xtst.XTestFakeMotionEvent(DPY, -1, x, y, 0)
    x11.XFlush(DPY)


def button(press: bool) -> None:
    xtst.XTestFakeButtonEvent(DPY, 1, 1 if press else 0, 0)
    x11.XFlush(DPY)


def stroke(points: list[tuple[int, int]]) -> None:
    """A freehand drag through `points` (absolute screen coords)."""
    motion(*points[0])
    time.sleep(0.1)
    button(True)
    for x, y in points[1:]:
        motion(x, y)
        time.sleep(0.02)
    button(False)
    time.sleep(0.2)


def window_geo(wid: int) -> tuple[int, int, int, int]:
    info = subprocess.check_output(["xwininfo", "-id", str(wid)], text=True)
    geo = dict(re.findall(
        r"(Absolute upper-left [XY]|Width|Height):\s+(\d+)", info))
    return (int(geo["Absolute upper-left X"]), int(geo["Absolute upper-left Y"]),
            int(geo["Width"]), int(geo["Height"]))


def capture(wid: int, out: str, crop_top: int | None = None) -> None:
    subprocess.run(["xwd", "-id", str(wid), "-silent", "-out", "/tmp/shot.xwd"],
                   check=True)
    if crop_top:
        # Keep only the top strip (window chrome shots): full width,
        # `crop_top` px tall, repaged so the PNG has no canvas offset.
        subprocess.run(["convert", "/tmp/shot.xwd", "-crop",
                        f"x{crop_top}+0+0", "+repage", out], check=True)
    else:
        subprocess.run(["convert", "/tmp/shot.xwd", out], check=True)
    print(f"wrote {out}")


def shoot(name: str, binary: str, title: str, outdir: str,
          args: list[str] | None = None, settle: float = 1.2,
          draw: bool = False, crop_top: int | None = None) -> None:
    """Launch one app, optionally draw into it, capture, terminate."""
    app = subprocess.Popen([f"bin/{binary}", *(args or [])])
    try:
        wid = wait_window(title)
        time.sleep(settle)
        focus_window(wid)
        if draw:
            wx, wy, ww, wh = window_geo(wid)
            cx, cy = wx + ww // 2, wy + wh // 2  # canvas center, roughly
            # Two synthetic strokes — a check-ish mark and an arc.
            stroke([(cx - 120, cy + 60), (cx - 40, cy - 50), (cx + 60, cy + 70),
                    (cx + 140, cy - 30)])
            time.sleep(0.3)
            stroke([(cx - 100, cy - 80), (cx, cy - 110), (cx + 100, cy - 80)])
            time.sleep(0.5)
        live = find_windows(title)
        capture(live[-1] if live else wid, os.path.join(outdir, f"{name}.png"),
                crop_top=crop_top)
    finally:
        app.terminate()
        try:
            app.wait(timeout=3)
        except subprocess.TimeoutExpired:
            app.kill()
        time.sleep(0.6)  # let the WM unmap before the next launch


def build(apps: list[str]) -> None:
    for app in apps:
        print(f"== rake build:release[{app}]")
        subprocess.run(["rake", f"build:release[{app}]"], check=True)


# DEMO.md template — image paths are relative to the repo root (the
# script's cwd), same as the README's.
DEMO_MD = """<!-- Generated by scripts/make_screenshots.py — do not edit;
     regenerate everything with: python3 scripts/make_screenshots.py -->

# egui-cr — demo

**Reactive, immediate-mode GUI for Crystal — pure Crystal UI.**
The only native dependency is the sokol_gfx backend; fonts render
through [freetype.cr](https://github.com/OrelSokolov/freetype.cr) and
SVG through [nanosvg.cr](https://github.com/OrelSokolov/nanosvg.cr) —
both pure Crystal.

## Notepad — tabbed editor, dark & light themes

Borderless window whose caption carries the tab strip; reactive tab
selection, routed settings/confirm pages, per-tab carets.

| Dark | Light |
|---|---|
| ![notepad dark]({outdir}/notepad-dark.png) | ![notepad light]({outdir}/notepad-light.png) |

## Borderless window frames

Client-side chrome drawn by `Egui::WindowFrame` — four looks, one
flag (`borderless --frame …`); drag to move, edge-drag to resize.

| ![Windows 11]({outdir}/frame-windows.png) |
|---|
| ![Windows XP]({outdir}/frame-xp.png) |
| ![Ubuntu]({outdir}/frame-ubuntu.png) |
| ![macOS]({outdir}/frame-macos.png) |

## Widget gallery — default & custom stylesheet

Every widget, twice: the built-in dark theme, then one custom
`ctx.stylesheet` theme (palette + cascade rules) restyling all of them
at once — no per-widget setup.

| Default dark | Custom stylesheet theme |
|---|---|
| ![widgets dark]({outdir}/widgets-dark.png) | ![widgets styled]({outdir}/widgets-styled.png) |

## Gradients & shadows

The Bootstrap 2.0.4 buttons, rebuilt on `Painter#box_shadow` (CSS
outset AND inset): gradient fills, inset sheen, pressed inset shadow,
dropdown popups with drop shadows — and the same look through plain
stylesheet `shadow.*` class rules.

![box shadow]({outdir}/box-shadow.png)

## Icon catalog

Every icon of the bundled sets (lucide · bootstrap) — SVGs rasterized
by [nanosvg.cr](https://github.com/OrelSokolov/nanosvg.cr), searchable,
live-recolorable.

![icons]({outdir}/icons.png)

## Paint

Drawing app on the same core — WinXP chrome, canvas with brush strokes
and the text tool.

![paint]({outdir}/paint.png)
"""


def write_demo(outdir: str) -> None:
    # DEMO.md sits at the repo root, next to README.md.
    path = os.path.join(os.path.dirname(outdir) or ".", "DEMO.md")
    with open(path, "w") as io:
        io.write(DEMO_MD.format(outdir=outdir))
    print(f"wrote {path}")

def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    flags = [a for a in sys.argv[1:] if a.startswith("-")]
    outdir = args[0] if args else "screenshots"
    os.makedirs(outdir, exist_ok=True)

    apps = ["notepad", "borderless", "widgets_gallery", "paint",
            "box_shadow", "icons_browser"]
    if "--no-build" not in flags:
        build(apps)

    # Notepad — the editor (root page) in both themes.
    shoot("notepad-dark", "notepad", "egui-cr — notepad", outdir,
          args=["--theme", "Dark", "README.md"])
    shoot("notepad-light", "notepad", "egui-cr — notepad", outdir,
          args=["--theme", "Light", "README.md"])

    # Borderless — the four client-side window frames (top strip only:
    # the caption + the look switcher is what differs between them).
    for frame in ("windows", "xp", "ubuntu", "macos"):
        shoot(f"frame-{frame}", "borderless", "egui-cr — borderless", outdir,
              args=["--frame", frame], crop_top=170)

    # Widget gallery — default dark, then the custom stylesheet theme.
    shoot("widgets-dark", "widgets_gallery", "egui-cr — widget gallery",
          outdir)
    shoot("widgets-styled", "widgets_gallery", "egui-cr — widget gallery",
          outdir, args=["--styled"])

    # Paint — with a couple of synthetic strokes on the canvas.
    shoot("paint", "paint", "untitled - Paint", outdir, settle=2.0, draw=True)

    # Gradients & shadows — the Bootstrap 2.0.4 button replica (gradient
    # fills, inset sheen, pressed inset shadow, dropdown shadow).
    shoot("box-shadow", "box_shadow",
          "egui.cr — box-shadow (bootstrap 2.0.4)", outdir, settle=1.5)

    # Icon catalog — the searchable lucide/bootstrap browser.
    shoot("icons", "icons_browser",
          "egui-cr — icons (lucide · bootstrap)", outdir, settle=2.5)

    # The gallery page embedding everything shot above.
    write_demo(outdir)


if __name__ == "__main__":
    main()
