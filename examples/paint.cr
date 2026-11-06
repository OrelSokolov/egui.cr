# egui-cr Windows XP Paint demo — bin/paint.
#
# A 1:1-arranged clone of MS Paint (XP era, tool set and button icons
# taken from jspaint's classic theme, see assets/paint/README.md):
# the 16-tool toolbox with per-tool option strips, the menu bar, the
# 28-color palette with the overlapped fg/bg swatch, the status bar
# with live cursor coordinates, and a real pixel canvas driven by the
# Egui::Canvas widget (nearest-sampled stream texture).
#
# Color styling is deliberately NOT 1:1 (Luna-ish silver instead of
# exact XP bitmaps) — only the buttons and layout are.
#
# File I/O goes through the SystemPorts dialogs (zenity/kdialog on
# Linux, osascript on macOS, WinForms/Win32 on Windows) and a pure
# stdlib PNG codec (examples/paint/png.cr) — fully cross-platform.
#
# MVC-миграция (plans/frontend-backend-split.md фаза 4): документ-слой
# — examples/paint_components/artwork.cr, вид —
# paint_components/paint_app.cr. Этот файл — точка входа.

require "../src/egui/driver_selector"
require "./paint_components/paint_app"

Egui.run(PaintApp.new,
  title: "untitled - Paint",
  # 692 tall so the default 640×480 canvas (plus chrome, toolbox,
  # palette, status bar and the classic-scrollbar reservations) fits
  # with slack to spare — the bottom resize grip and its marker must
  # stay visible even after a small corner-drag grow.
  width: 880, height: 692,
  decorations: false,
  chrome_style: Egui::WindowFrame::Style::WindowsXp,
  inspector: :hidden)
