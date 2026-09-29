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
# framework's AppConfig system port (XDG on Linux, Application Support
# on macOS, APPDATA on Windows). Settings live in the right side panel
# (the Settings menu in the menu bar — a section of its own, not a File
# entry).

require "../src/egui"
require "../src/egui/backend/sokol"
require "../src/egui/terminal/pty"

class TerminalApp < Egui::App
  # Lowest useful window opacity (below this, text gets unreadable).
  MIN_OPACITY = 0.3

  class Tab
    getter session : Egui::Terminal::Session
    property title : String

    def initialize(@session : Egui::Terminal::Session, @title : String)
    end

    # `wake` is hooked to the session's on_output: PTY data arrived in
    # the reader fiber — request a repaint so the frame loop pumps it
    # into the emulator instead of waiting for the next input event.
    def self.open(cwd : String? = nil, &wake : Proc(Nil)) : Tab
      shell = Egui::Terminal::Session.default_shell
      session = Egui::Terminal::Session.new(shell: shell, cwd: cwd,
        cols: 80, rows: 24, on_output: wake)
      new(session, File.basename(shell))
    end
  end

  # Tabs are a signal and the selection is DERIVED from them: whenever
  # the list changes (tab opened, closed, or dead child reaped), the
  # computed clamps the picked index — a dying active tab automatically
  # falls onto the remaining neighbor/last tab. No per-call-site clamp.
  reactive tabs : Array(Tab) = [] of Tab
  # The user's last explicit choice (tab click, menu item, hotkey,
  # close); the ACTIVE tab is always `selected` below.
  reactive picked = 0
  computed selected : Int32 = picked.clamp(0, {tabs.size - 1, 0}.max)

  # App actions (menus and hotkeys reference these, never key strings).
  ACTION_NEW_TAB   = Egui::HotkeyAction.new("terminal.new_tab")
  ACTION_CLOSE_TAB = Egui::HotkeyAction.new("terminal.close_tab")
  DEFAULT_BINDINGS = {
    ACTION_NEW_TAB   => "Ctrl+T",
    ACTION_CLOSE_TAB => "Ctrl+W",
  }
  @hotkeys_ready = false

  # User profiles (loaded in `main` below). The saved opacity is the
  # TERMINAL background opacity (alacritty's background_opacity): the
  # window runs in per-pixel-transparent mode and the terminal area
  # alone carries that alpha — the menu / tab strip / settings /
  # status panels stay opaque.
  getter config : Egui::Terminal::Config
  # The terminal look applied to every tab; #apply_appearance retunes
  # it from the active profile each frame.
  getter theme : Egui::Terminal::Theme
  property? settings_open : Bool = false
  @new_profile_name : String = ""
  # Set when a settings widget changed something → the Save button (and
  # only it) writes the file; the marker shows as "Save •".
  @dirty : Bool = false

  def initialize(@config : Egui::Terminal::Config)
    super()
    @theme = Egui::Terminal::Theme.new
    new_tab
    self.picked = 0
  end

  def update(ctx : Egui::Context) : Nil
    # The saved look → the live theme + panel fills (cheap, every
    # frame, so a profile switch or slider drag shows immediately).
    apply_appearance(ctx)

    # A dead child closes its tab (typed `exit` in bash, killed shell);
    # when the LAST tab goes, the whole app exits with its window.
    live = tabs.reject { |tab| !tab.session.alive? }
    self.tabs = live unless live.size == tabs.size
    Egui::SystemPorts::Quit.quit! if tabs.empty?

    # Hidden sessions don't render, but their PTYs keep producing.
    # One evented pass for the whole frame (the first caller pays the
    # ~1 ms select; TermView's call below rides on the same deduped
    # pass) wakes every reader fiber, then drain each hidden session —
    # a drain alone is cheap, so the frame cost no longer scales with
    # the tab count. Without these a hidden tab's title would stick
    # at "bash" until it's clicked and rendered.
    tabs.first?.try &.session.evented_pass(ctx.input.time)
    tabs.each_with_index do |tab, i|
      next if i == selected
      tab.session.pump
    end
    # Titles sync BEFORE the tab bar is drawn, so every tab shows its
    # shell's current OSC title this same frame.
    tabs.each do |tab|
      title = tab.session.term.title
      tab.title = title unless title.empty?
    end

    # Default hotkey bindings — once, on the first frame.
    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    ctx.menu_bar do |bar|
      bar.menu_button("File") do |menu|
        menu.menu_item("New Tab", ACTION_NEW_TAB)
        menu.menu_item("Close Tab", ACTION_CLOSE_TAB)
      end
      # Clipboard bridge. The hints are static strings on purpose:
      # TermView already handles Ctrl+Shift+C/V (and the smart Ctrl+C)
      # itself when focused — binding the same combos to actions here
      # would double-fire a paste.
      bar.menu_button("Edit") do |menu|
        menu.menu_item("Copy", icon: :copy, hotkey: "Ctrl+Shift+C") { copy_selection }
        menu.menu_item("Paste", icon: :paste, hotkey: "Ctrl+Shift+V") { paste_clipboard }
      end
      # Settings is a section of its own, not a File entry.
      bar.menu_button("Settings") do |menu|
        menu.menu_item(settings_open? ? "Hide Settings" : "Settings…") do
          self.settings_open = !settings_open?
        end
      end
    end

    # Settings: the active profile's opacity / background / cursor
    # blink, editable live; every change marks the config dirty and
    # persists at the end of the frame.
    if settings_open?
      ctx.side_panel(:right, "settings", width: 300.0) do |ui|
        profile = config.active_profile

        ui.heading("Settings")
        ui.combo_box("profile", config.active,
                     config.profiles.keys) { |name| config.active = name }
        ui.horizontal do |row|
          row.text_edit_singleline(@new_profile_name,
            hint: "new profile name") { |t| @new_profile_name = t }
          if row.button("Add").clicked? &&
             !(name = @new_profile_name.strip).empty?
            config.profiles[name] = profile.dup
            config.active = name
            @new_profile_name = ""
            @dirty = true
          end
          if row.button("Delete").clicked? && config.profiles.size > 1
            config.profiles.delete(config.active)
            config.active = config.profiles.keys.first
            @dirty = true
          end
        end
        ui.separator

        ui.label("Terminal background opacity:")
        ui.slider(profile.opacity, MIN_OPACITY..1.0) do |v|
          profile.opacity = v
          @dirty = true
        end
        ui.separator

        ui.label("Background color:")
        ui.color_edit32(profile.background_color) do |c|
          profile.background_color = c
          @dirty = true
        end
        ui.separator

        ui.checkbox(profile.cursor_blinks, "Blinking cursor") do |v|
          profile.cursor_blinks = v
          @dirty = true
        end

        # Explicit save — edits apply to the look immediately but only
        # reach the JSON file here.
        ui.separator
        if ui.button(@dirty ? "Save •" : "Save").clicked?
          @dirty = false
          config.save
        end
      end
    end

    ctx.central_panel do |ui|
      unless tabs.empty?
        ui.tabs(titles, selected, closable: true,
          on_close: ->(t : Int32) { close_tab(t) }) do |t|
          self.picked = t
        end

        # Only the ACTIVE tab renders — hidden sessions are pumped in
        # #update (their output is fed to the emulator there; nothing
        # waits on rendering).
        tab = tabs[selected]?
        if tab
          resp = ui.terminal(tab.session, theme: theme,
            cursor_blinks: config.active_profile.cursor_blinks)
          # Give the terminal keyboard focus when its tab becomes the
          # active one (identity, not index: index reuse must not
          # swallow the hand-off).
          unless tab.same?(@focused_tab)
            @focused_tab = tab
            ctx.memory.focus.request(resp.id)
          end
          # Right-click menu: Copy/Paste over the active session (the
          # same handlers the Edit menu uses).
          resp.context_menu(term_menu)
        end
      end
    end

    ctx.bottom_panel("status") do |ui|
      tab = tabs[selected]?
      if tab && (code = tab.session.exit_code)
        ui.label("exited: #{code}")
      else
        ui.label("FPS: #{"%.1f" % ctx.fps} — " \
                 "#{tab.try &.session.term.cols}×#{tab.try &.session.term.rows}" \
                 " — scrollback #{tab.try &.session.term.display_offset}" \
                 " — #{config.active}")
      end
    end

    # Action dispatch runs last so menu-click re-firings and hotkey
    # presses meet one handler.
    if ctx.consume_action(ACTION_NEW_TAB)
      new_tab
      self.picked = tabs.size - 1
    end
    close_tab(selected) if ctx.consume_action(ACTION_CLOSE_TAB) && !tabs.empty?
  end

  private def titles : Array(String)
    tabs.map_with_index { |tab, i| i == selected ? "▸ #{tab.title}" : tab.title }
  end

  # The active profile → the terminal theme. Opacity is the ALPHA of
  # the terminal background only: TermView writes it as a REPLACE rect
  # (overwrites the framebuffer alpha), so the desktop shows through
  # the grid and NOTHING else — the menu, tab strip, settings and
  # status panels keep their opaque fills.
  private def apply_appearance(ctx : Egui::Context) : Nil
    profile = config.active_profile
    alpha = (profile.opacity.clamp(MIN_OPACITY, 1.0) * 255.0).round.to_u8
    bg = profile.background_color
    theme.background = Egui::Color32.new(bg.r, bg.g, bg.b, alpha)
  end

  private def new_tab : Nil
    # App#ctx exists from the constructor — the reader fiber can wake
    # the frame loop from the very first tab on. Reassign, don't `<<`:
    # only the setter dirties dependents (the selected computed).
    self.tabs = tabs + [Tab.open { ctx.request_repaint }]
  end

  private def close_tab(t : Int32) : Nil
    list = tabs.dup
    tab = list.delete_at(t)
    self.tabs = list
    tab.session.close
  end

  # The right-click menu over the terminal (Edit-menu items again).
  @term_menu : Egui::ContextMenu?
  private def term_menu : Egui::ContextMenu
    @term_menu ||= Egui::ContextMenu.new
      .item("Copy", icon: :copy, hotkey: "Ctrl+Shift+C") { copy_selection }
      .item("Paste", icon: :paste, hotkey: "Ctrl+Shift+V") { paste_clipboard }
  end

  # Copy the active tab's selection to the system clipboard. TermView
  # owns the selection gestures (drag/double/triple click);
  # selection_text is nil with nothing selected — Copy then no-ops,
  # like egui_term's Copy without a selection.
  private def copy_selection : Nil
    tab = tabs[selected]?
    return unless tab
    if (sel = tab.session.term.selection_text)
      Egui::SystemPorts::Clipboard.text = sel
    end
  end

  # Paste the system clipboard into the active tab's child — through
  # Terminal#paste_bytes, so a child in bracketed-paste mode (vim,
  # less) gets the ESC[200~ wrapping instead of raw text.
  private def paste_clipboard : Nil
    tab = tabs[selected]?
    return unless tab
    if (text = Egui::SystemPorts::Clipboard.text)
      tab.session.write(tab.session.term.paste_bytes(text))
    end
  end

  @focused_tab : Tab? = nil
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

  font = Egui::Backend::FreetypeFonts.from_system(candidates)
  font ||= Egui::Backend::LightHintedFonts.from_system(candidates)
  Egui::Backend::Sokol.select_fonts(font) if font
end

pick_monospace

# The profiles load before the app starts. The window runs in
# per-pixel-transparent mode (depth-32 ARGB visual + premultiplied
# blending; the pipelines' RGBA write masks make the alpha survive to
# the compositor — sgl's implicit default is RGB-only). Only the
# terminal grid carries alpha (TermView's replace rect); every panel
# around it stays opaque.
config = Egui::Terminal::Config.load

Egui::Backend::Sokol.run(TerminalApp.new(config),
  title: "egui-cr — terminal", width: 900, height: 640,
  transparent: true, inspector: :hidden)
