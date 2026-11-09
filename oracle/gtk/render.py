#!/usr/bin/env python3
"""GNOME widget oracle renderer — native GTK4/libadwaita → PNG.

The GTK twin of oracle/macos/render.swift: one flat 480×160 sheet per
widget, light Adwaita, no window chrome, no focus, no hover. Widgets
sit at the same skeleton as the macOS sheets — first column x=24,
second x=250, vertically centered on the y=80 midline — so the egui
twin harness (scripts/make_gnome_oracle_shots.cr) renders against the
same geometry.

Headless capture: the sheet is an undecorated Adw.ApplicationWindow
mapped on an X display (Xvfb-class is fine — DISPLAY=:1 on this box),
grabbed per sheet with xwd -id + convert.

    cd oracle/gtk && python3 render.py   # → png/<sheet>.png
"""

import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

SHEET_W, SHEET_H = 480, 160
COL1_X, COL2_X, MID_Y = 24, 250, 80
SHEET_BG = (250, 250, 250)  # libadwaita light window_bg_color (#FAFAFA)
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "png")
XWD_TMP = "/tmp/gtk_oracle.xwd"

SHEETS = [
    "button", "checkbox", "radio", "switch", "text_field",
    "search_field", "slider", "segmented", "popup", "progress",
    "stepper", "label",
]

# Per-sheet column x for each child (progress pads its spinner to the
# twin's 56pt gap; single-widget sheets keep one column).
SPINNER_GAP = 56


def make_sheet(name):
    """Build one sheet: [(x, widget), …]. y is set later (centering)."""
    def button(text, css=None):
        b = Gtk.Button(label=text)
        if css:
            b.add_css_class(css)
        return b

    def check(label, active=False, group=None):
        c = Gtk.CheckButton(label=label)
        if group:
            c.set_group(group)
        c.set_active(active)
        return c

    if name == "button":
        return [(COL1_X, button("Button")),
                (COL2_X, button("OK", "suggested-action"))]
    if name == "checkbox":
        return [(COL1_X, check("Check")),
                (COL2_X, check("Selected", active=True))]
    if name == "radio":
        first = check("First", active=True)
        return [(COL1_X, first),
                (COL2_X, check("Second", group=first))]
    if name == "switch":
        def switch(active):
            s = Gtk.Switch()
            s.set_active(active)
            return s
        return [(COL1_X, switch(False)), (COL2_X, switch(True))]
    if name == "text_field":
        e = Gtk.Entry()
        e.set_text("Placeholder")  # real text — the twin shows it black
        e.set_size_request(200, -1)
        return [(COL1_X, e)]
    if name == "search_field":
        se = Gtk.SearchEntry()
        se.set_placeholder_text("Search")
        se.set_size_request(222, -1)
        return [(COL1_X, se)]
    if name == "slider":
        sc = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL,
                                      0.0, 1.0, 0.01)
        sc.set_value(0.6)
        sc.set_draw_value(False)
        sc.set_size_request(220, -1)
        return [(COL1_X, sc)]
    if name == "segmented":
        # No native Adwaita segmented — linked toggle buttons (the
        # standard GNOME grouping for pick-one-of-N).
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        box.add_css_class("linked")
        for i, text in enumerate(("One", "Two", "Three")):
            tb = Gtk.ToggleButton(label=text)
            tb.set_active(i == 1)
            box.append(tb)
        return [(COL1_X, box)]
    if name == "popup":
        dd = Gtk.DropDown.new_from_strings(["First", "Second", "Third"])
        dd.set_selected(0)
        dd.set_size_request(200, -1)
        return [(COL1_X, dd)]
    if name == "progress":
        pb = Gtk.ProgressBar()
        pb.set_fraction(0.45)
        pb.set_size_request(200, -1)
        sp = Gtk.Spinner()
        sp.set_spinning(True)
        # Spinner x is resolved after map (bar width + gap) in
        # center_and_capture; both start at column 1.
        return [(COL1_X, pb), (COL1_X, sp)]
    if name == "stepper":
        sb = Gtk.SpinButton.new_with_range(0, 100, 1)
        sb.set_value(42)
        # Natural width — the egui NumberInput twin has no fixed-width
        # mode (sized by its widest value); forcing 200 here would
        # put a permanent gap in the diff (see FINDINGS).
        return [(COL1_X, sb)]
    if name == "label":
        l1 = Gtk.Label(label="Label")
        l2 = Gtk.Label(label="Dim label")
        l2.add_css_class("dim-label")
        return [(COL1_X, l1), (COL2_X, l2)]
    raise ValueError(name)


class Renderer(Adw.Application):
    def __init__(self):
        super().__init__(application_id="org.egui.cr.gtkoracle")
        self.window = None
        self.fixed = None
        self.queue = list(SHEETS)

    def do_activate(self):
        # Always light Adwaita, independent of the system theme.
        Adw.StyleManager.get_default().set_color_scheme(
            Adw.ColorScheme.FORCE_LIGHT)
        # Stock GNOME text: Cantarell 11 — pinned explicitly so the
        # session's font (Ubuntu 11) can't leak through settings.
        Gtk.Settings.get_default().set_property(
            "gtk-font-name", "Cantarell 11")
        self.window = Adw.ApplicationWindow(application=self)
        self.window.set_decorated(False)
        self.window.set_default_size(SHEET_W, SHEET_H)
        # Kill the CSD chrome — without a WM the X11 surface carries
        # shadow margins and the window outline INTO the capture; the
        # sheets are solid background to the edge (macOS oracle rule).
        css = Gtk.CssProvider()
        css.load_from_data(
            "window.csd { box-shadow: none; border: none; outline: none; }"
            .encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.fixed = Gtk.Fixed()
        self.window.set_content(self.fixed)
        self.window.present()
        GLib.timeout_add(300, self.next_sheet)

    def next_sheet(self):
        if not self.queue:
            self.quit()
            return False
        name = self.queue.pop(0)
        while (child := self.fixed.get_first_child()) is not None:
            self.fixed.remove(child)
        self.window.set_title(f"oracle-{name}")
        for x, w in make_sheet(name):
            self.fixed.put(w, x, 0)
        # First frame allocates; then center on the midline and grab.
        GLib.timeout_add(400, lambda: self.center_and_capture(name))
        return False

    def center_and_capture(self, name):
        kids = list(children_of(self.fixed))
        for i, child in enumerate(kids):
            _min, nat, _mb, _nb = child.measure(Gtk.Orientation.VERTICAL, -1)
            if name == "progress" and i == 1:
                x = COL1_X + kids[0].get_width() + SPINNER_GAP
            else:
                x = (COL1_X, COL2_X)[i]
            self.fixed.move(child, x, MID_Y - nat / 2)
        GLib.timeout_add(250, self.capture_and_advance, name)
        return False

    def capture_and_advance(self, name):
        self.grab(name)
        GLib.idle_add(self.next_sheet)
        return False

    def grab(self, name):
        out = os.path.join(OUT_DIR, f"{name}.png")
        # The X window id straight from the GDK surface — hunting it
        # in xwininfo's tree is fragile (mutter reparenting, unnamed
        # helper windows), the xid is exact.
        try:
            gi.require_version("GdkX11", "4.0")
            from gi.repository import GdkX11
            wid = self.window.get_surface().get_xid()
        except Exception as e:
            print(f"!! no xid for {name}: {e}", file=sys.stderr)
            return
        r = subprocess.run(
            ["xwd", "-id", str(wid), "-silent", "-out", XWD_TMP],
            capture_output=True)
        if r.returncode != 0:
            print(f"!! xwd failed for {name}: {r.stderr}", file=sys.stderr)
            return
        subprocess.run(["convert", XWD_TMP, out], check=True)
        # The no-WM X11 surface carries CSD margins + the window
        # outline ring, so the sheet sits at an unknown offset inside
        # the capture. Find the content origin exactly: scan the
        # widget midline for the first run of clean sheet background
        # past the ring (same for a column), then crop there.
        from PIL import Image
        im = Image.open(out).convert("RGB")
        w, h = im.size
        ax, ay = self.fixed.get_allocation().x, self.fixed.get_allocation().y
        mid_y = min(max(ay + MID_Y, 0), h - 1)
        mid_x = min(max(ax + SHEET_W // 2, 0), w - 1)

        # Content x0: first x on the midline with 16 consecutive pure
        # sheet-bg px (the ring/AA blends break the run).
        x0 = ax
        for x in range(0, w - 16):
            if all(im.getpixel((x + i, mid_y)) == SHEET_BG for i in range(16)):
                x0 = x
                break
        y0 = ay
        for y in range(0, h - 16):
            if all(im.getpixel((mid_x, y + i)) == SHEET_BG for i in range(16)):
                y0 = y
                break
        canvas = Image.new("RGB", (SHEET_W, SHEET_H), SHEET_BG)
        region = im.crop((x0, y0, x0 + SHEET_W, y0 + SHEET_H))
        canvas.paste(region, (0, 0))
        # The crop's right/bottom edges can run past the content into
        # the window margin (a dark blend line). Nothing of the
        # widgets lives there (columns end well before x=479) — pad
        # the border strips back to sheet bg.
        from PIL import ImageDraw
        dr = ImageDraw.Draw(canvas)
        dr.rectangle([SHEET_W - 3, 0, SHEET_W - 1, SHEET_H - 1], fill=SHEET_BG)
        dr.rectangle([0, SHEET_H - 3, SHEET_W - 1, SHEET_H - 1], fill=SHEET_BG)
        canvas.save(out)
        print(out)


def children_of(fixed):
    child = fixed.get_first_child()
    while child is not None:
        yield child
        child = child.get_next_sibling()


def run_gallery():
    """Live gallery window: every sheet stacked up with captions —
    the GTK twin of `oracle/macos/render.swift render gallery`.
    Interactive, runs until closed.

      cd oracle/gtk && python3 render.py gallery
    """
    Adw.init()
    Adw.StyleManager.get_default().set_color_scheme(
        Adw.ColorScheme.FORCE_LIGHT)
    Gtk.Settings.get_default().set_property(
        "gtk-font-name", "Cantarell 11")
    window = Adw.ApplicationWindow()
    window.set_title("GTK/libadwaita Widget Gallery (native oracle)")
    window.set_default_size(520, 20 + len(SHEETS) * 64)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL,
                  spacing=4, margin_top=12, margin_bottom=12,
                  margin_start=24, margin_end=24)
    for name in SHEETS:
        caption = Gtk.Label(label=name, xalign=0)
        caption.add_css_class("dim-label")
        caption.set_halign(Gtk.Align.START)
        box.append(caption)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=28)
        for x, w in make_sheet(name):
            w.set_margin_bottom(8)
            row.append(w)
        box.append(row)
    window.set_content(box)
    window.present()
    loop = GLib.MainLoop()
    window.connect("close-request", lambda *_: loop.quit())
    loop.run()


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    if "gallery" in sys.argv:
        run_gallery()
    else:
        Renderer().run()
