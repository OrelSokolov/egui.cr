# egui-cr notepad — a Windows 11 Notepad-style tabbed text editor:
# borderless window whose CAPTION carries the tab strip (TitleBarTabs
# through the WindowFrame caption hook) next to the caption buttons —
# active tab lighter, rounded-top cards, a dirty-dot marker that
# becomes an X on hover, a "+" new-tab button, carousel scrolling when
# the tabs overflow. Below the caption: a File menu with hotkey hints
# (New / Open… / Save / Save As… / Close Tab / Quit), a View menu, a
# Settings menu of its own (not a File entry), a per-document
# textarea and a status bar. The app is a set of routed PAGES
# (Egui::Router): root/root the editor, root/settings the full-window
# settings page, root/confirm-close the unsaved-changes confirmation
# (a modal page — "a modal is just a page"); deep links work:
# `notepad --page root/settings#search`. Each tab's editor runs in a
# child Ui id'd per document, so every document keeps its own caret
# and selection across tab switches; keyboard focus follows the tab
# selection signal. The theme choice persists as JSON through the
# AppConfig system port.
#
# MVC-миграция (plans/frontend-backend-split.md фаза 4): backend
# приложения — examples/notepad_components/backend.cr (Document-ресурс,
# DocumentsController c CRUD + confirm-цепочкой и quit-флоу,
# SettingsController c AppConfig; файлы/диалоги/MIME — там), вид —
# examples/notepad_components/notepad_app.cr. Этот файл — только
# точка входа. notepad_with_exml.cr остаётся на старой схеме до
# своей очереди миграции.

require "json"

require "./icon" # ICON_64_RGBA — the shared app icon (64x64 RGBA)
require "./notepad_components/notepad_app"
# Embedded builds (EGUI_EMBEDDED=1 at COMPILE time — Capybara screenshot
# / suite scripts require this file as a library) skip the driver
# entirely: a headless test binary links no sokol, no X11.
{% unless env("EGUI_EMBEDDED") %}require "../src/egui/driver_selector"{% end %}

{% unless env("EGUI_EMBEDDED") %}
cli = Egui::CLI.parse(ARGV)
# `--theme Dark|Light` — a palette override for this run (screenshots);
# pulled out of the file list before the app sees it.
theme = nil
files = [] of String
argv = cli[:argv].dup
argv.each_with_index do |arg, i|
  if arg == "--theme" && (value = argv[i + 1]?)
    theme = value
  elsif argv[i - 1]? == "--theme"
    next
  else
    files << arg
  end
end
app = NotepadApp.new(files, theme)
if (route = cli[:route])
  app.ctx.router.navigate(route)
end
Egui.run(app,
  title: "egui-cr — notepad", width: 800, height: 600,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64},
  decorations: false, inspector: :hidden)
{% end %}
