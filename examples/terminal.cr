# egui-cr terminal — a tabbed terminal emulator (egui_term's role,
# on egui-cr): a shell in a PTY per tab, rendered by the TermView
# widget. Tabs live in a File menu with the standard hotkeys (Ctrl+T
# new, Ctrl+W close); the tab titles follow the child's OSC title
# (bash/vim set them); closing a tab kills the session, and a dead
# child closes its tab — the last tab (closed or dead) exits the whole
# app.
#
# Requires the native library (rake build:native compiles the PTY shim
# into it) and a monospace font, selected per-platform below.
#
# User profiles (opacity / background color / cursor blink) persist as
# JSON through Terminal::ConfigStore — the terminal face of the
# framework's AppConfig system port.
#
# MVC-миграция (plans/frontend-backend-split.md фаза 4): контрольная
# плоскость сессий и профили — examples/terminal_components/backend.cr
# (SessionsController/ProfilesController, State-слайсы), вид —
# terminal_components/terminal_app.cr. Этот файл — точка входа:
# нативная PTY-фабрика, моно-шрифт, запуск.

require "../src/egui/driver_selector"
require "../src/egui/driver/pty"
require "./terminal_components/terminal_app"

# Нативная PTY-фабрика сессий (backend.cr остаётся driver-free —
# спеки подменяют фабрику фейком). Явный тип возврата: Proc
# ковариантностью не обладает.
TerminalRepo.session_factory = ->(cwd : String?, wake : Proc(Nil)) : Egui::Terminal::Backend do
  shell = Egui::Terminal::Session.default_shell
  Egui::Terminal::Session.new(shell: shell, cwd: cwd,
    cols: 80, rows: 24, on_output: wake)
end

# Monospace font: prefer real mono faces per platform; the FreeType
# backend needs a file. Falls back to the app default (proportional —
# degraded but functional).
def pick_monospace : Nil
  candidates = [
    "JetBrainsMonoNerdFontMono-Regular.ttf",
    "JetBrainsMono-Regular.ttf",
  ]
  {% if flag?(:win32) %}
    candidates += ["C:\\Windows\\Fonts\\consola.ttf",
                   "C:\\Windows\\Fonts\\lucon.ttf"]
  {% else %}
    candidates += [
      "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
      "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
      "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/ubuntu/UbuntuMono-R.ttf",
      "/System/Library/Fonts/SFMono-Regular.ttf",
      # Stock macOS ships SF Mono as SFNSMono.ttf (SFMono-Regular.ttf
      # only exists inside Terminal.app/Xcode bundles). Without a mono
      # candidate the app font (proportional SF) wins and the terminal
      # cursor drifts off the text — TermView assumes uniform advances.
      "/System/Library/Fonts/SFNSMono.ttf",
      "/Library/Fonts/JetBrainsMono-Regular.ttf",
    ]
  {% end %}

  font = Egui::Driver::Sokol.fonts_from_system(candidates)
  Egui::Driver::Sokol.select_fonts(font) if font
end

pick_monospace

Egui.run(TerminalApp.new,
  title: "egui-cr — terminal", width: 900, height: 640)
