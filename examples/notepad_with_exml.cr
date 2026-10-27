# egui-cr notepad (exml) — the Windows 11 Notepad-style tabbed editor
# with the interface itself declared in assets/notepad.exml and
# hot-reloaded from there. The layout is COMPOSED: the page is three
# <use> lines pulling named partials (menu, editor, status panel);
# custom elements pick the shape that fits — <fps_meter/> is a
# stateless top-level `widget` handler (one block, no class), while
# <status_bar/> (derived chars/lines) is a Component class
# (notepad_components/). The logic (documents, tabs, dialogs,
# hotkeys, focus, persistence) stays in this binary and reaches the
# markup through the exml store (named values) and the action
# registry (named procs).
#
# What stays native on purpose (see src/egui/exml.cr header):
#   * the caption tab strip — a WindowFrame caption hook, not a
#     renderable region;
#   * hotkey bindings — the markup carries hint text only.
#
# Same frame as the plain notepad example for a side-by-side read:
# every `r.page do … end` body there became markup here, and every
# callback there became an action registration.

require "json"
require "mime"

require "./icon" # ICON_64_RGBA — the shared app icon (64x64 RGBA)
# Custom elements, one file each in notepad_components/:
# <status_bar/> (chars/lines derivation) — a stateful Component
# class; <fps_meter/> (the live FPS reading) — a stateless top-level
# `widget` handler in the global registry.
require "./notepad_components/status_bar"
require "./notepad_components/fps_meter"
# Embedded builds (EGUI_EMBEDDED=1 at COMPILE time — Capybara screenshot
# / suite scripts require this file as a library) skip the backend
# entirely: a headless test binary links no sokol, no X11.
{% unless env("EGUI_EMBEDDED") %}require "../src/egui/backend_selector"{% end %}

class NotepadExmlApp < Egui::App
  # Debug builds keep the inspector's style edits in a `.ecss` diff file
  # next to the binary (style_notepad_exml.ecss) — see src/egui/ecss.cr.
  enable_ecss "notepad_exml"

  # Persisted settings (the AppConfig system port): stored as JSON in
  # the user config dir (~/.config/notepad_exml/settings.json et al.)
  # and reloaded on start. A missing or corrupt file yields defaults.
  class Settings
    include JSON::Serializable

    property theme : String = "Dark"

    def initialize(@theme : String = "Dark")
    end
  end

  # The theme dropdown options, in display order (the markup's combo
  # carries the same list — options="Dark, Light").
  THEMES = ["Dark", "Light"]

  TEXT_MIME_EXTRAS = {"application/json", "application/xml",
                      "application/yaml", "application/x-yaml",
                      "application/toml", "application/javascript"}

  # One open document: its text, the file it came from (nil = never
  # saved) and the dirty flag (edits since the last save).
  class Doc
    property text : String
    property path : String?
    property? dirty : Bool = false
    getter name : String
    def initialize(@text : String = "", @path : String? = nil,
                   @name : String = "untitled")
    end

    def title : String
      (p = @path) ? File.basename(p) : @name
    end
  end

  @docs = [Doc.new(
    "Welcome to the egui-cr notepad — EXML edition!\n" \
    "\n" \
    "The interface you are looking at is not code: it is\n" \
    "assets/notepad.exml, parsed at startup and hot-reloaded\n" \
    "on every save — edit that file while this app runs.\n" \
    "\n" \
    "Ctrl+N — new tab, Ctrl+O — open a file, Ctrl+S — save.\n" \
    "Each tab keeps its own caret and selection.\n")]

  # The tab selection drives the exml editor_id interpolation —
  # the renderer's child-Ui (and focus) follows it.
  reactive selected = 0

  @status = "Ready."
  @hotkeys_ready = false
  @next_untitled = 1
  # A dirty document awaiting the Save / Don't save / Cancel choice
  # (the confirmation modal is open for it).
  @pending_close : Doc? = nil
  # Quit is running: confirm every dirty document, then really quit.
  @quitting = false
  @show_fps = false
  @settings : Settings = Egui::SystemPorts::AppConfig.load(
    "notepad_exml", Settings.new)

  # --- the exml side -------------------------------------------------

  # The parsed markup document (hot-reloaded on external edits).
  @exml : Egui::Exml::Document
  # One renderer across frames — it remembers the last editor child-Ui
  # id to drive focus-follows-tab.
  @renderer = Egui::Exml::Renderer.new
  # The store + action registry the markup binds to.
  @rt = Egui::Exml::Runtime.new

  # Locate the markup: EGUI_EXML=env override, then the repo checkout
  # (__DIR__/../assets), then the working directory — in that order.
  def self.exml_path : String
    candidates = [
      ENV["EGUI_EXML"]?,
      File.join(__DIR__, "..", "assets", "notepad.exml"),
      File.join("assets", "notepad.exml"),
    ].compact
    candidates.each do |c|
      return c if File.file?(c)
    end
    candidates.last # Document.load reports the missing file itself
  end

  # Vocabulary lint: the document's elements/attrs against the widget
  # vocabulary, plus this app's custom elements. Silent when clean;
  # issues land in the console with document paths (startup + every
  # hot reload).
  private def lint_exml : Nil
    # fps_meter needs no listing: the linter knows the global `widget`
    # registry (see Exml.validate).
    Egui::Exml.validate(@exml,
      known_custom: %w(status_bar))
      .each { |i| STDERR.puts "exml: #{i}" }
  end

  def initialize(files : Array(String) = [] of String, theme : String? = nil)
    super()
    @exml = Egui::Exml::Document.load(self.class.exml_path)
    lint_exml
    # Screenshot/theme override: `notepad --theme Light file.txt` forces
    # the palette for this run without touching the saved settings.
    @settings.theme = theme if theme
    # Win11 Notepad chrome: the tabs live IN the caption, left of the
    # caption buttons. The caption hook is native by design — exml has
    # no reach into WindowFrame hooks (see the file header).
    Egui::WindowFrame.caption(
      height: Egui::TitleBarTabs::CAPTION_H) do |ctx, area|
      unless ctx.router.current.page == "settings"
        Egui::TitleBarTabs.show(ctx, area, @docs.map(&.title), selected,
          dirty: @docs.map(&.dirty?),
          on_select: ->(t : Int32) { self.selected = t; nil },
          on_close: ->(t : Int32) { request_close(@docs[t]?) },
          on_new: -> { new_doc })
      end
    end
    register_actions
    # <status_bar/> — the stateful custom element (a Component class).
    # <fps_meter/> needs no registration here: notepad_components/
    # fps_meter.cr put it in the global `widget` registry at require.
    @renderer.component(StatusBar.new)
    # Files passed on the command line open straight into tabs.
    opened = 0
    files.each do |arg|
      opened += 1 if open_at_startup(arg)
    end
    if opened > 0
      @docs.shift if @docs.size > 1
      self.selected = @docs.size - 1
    end
  end

  # App actions (menus and hotkeys reference these, never key strings).
  ACTION_NEW      = Egui::HotkeyAction.new("notepad.new")
  ACTION_OPEN     = Egui::HotkeyAction.new("notepad.open")
  ACTION_SAVE     = Egui::HotkeyAction.new("notepad.save")
  ACTION_SAVE_AS  = Egui::HotkeyAction.new("notepad.save_as")
  ACTION_CLOSE    = Egui::HotkeyAction.new("notepad.close")
  ACTION_QUIT     = Egui::HotkeyAction.new("notepad.quit")
  ACTION_NEXT_TAB = Egui::HotkeyAction.new("notepad.next_tab")
  ACTION_PREV_TAB = Egui::HotkeyAction.new("notepad.prev_tab")
  ACTION_SETTINGS = Egui::HotkeyAction.new("notepad.settings")

  DEFAULT_BINDINGS = {
    ACTION_NEW      => "Ctrl+N",
    ACTION_OPEN     => "Ctrl+O",
    ACTION_SAVE     => "Ctrl+S",
    ACTION_SAVE_AS  => "Ctrl+Shift+S",
    ACTION_CLOSE    => "Ctrl+W",
    ACTION_QUIT     => "Ctrl+Q",
    ACTION_NEXT_TAB => "Ctrl+Tab",
    ACTION_PREV_TAB => "Ctrl+Shift+Tab",
    ACTION_SETTINGS => "Ctrl+Comma",
  }

  # The markup's named actions → app logic. Registered once; fired by
  # menu items, buttons and the modal footer straight from exml.
  private def register_actions : Nil
    a = @rt.actions
    a["new"]        = ->{ new_doc }
    a["open"]       = ->{ open_doc }
    a["save"]       = ->{ save_doc }
    a["save_as"]    = ->{ save_doc_as }
    a["close"]      = ->{ close_tab if !@docs.empty? }
    a["quit"]       = ->{ quit_flow }
    a["next_tab"]   = ->{ next_tab }
    a["prev_tab"]   = ->{ previous_tab }
    a["settings"]   = ->{ ctx.router.navigate("root/settings") }
    a["toggle_fps"] = ->{ @show_fps = !@show_fps }
    # The active document's buffer is a store slot; the textarea's
    # on_change writes it and fires here.
    a["doc_edited"] = ->{
      if (doc = @docs[selected]?)
        doc.text = @rt.string("doc_text")
        doc.dirty = true
      end
    }
    a["theme_changed"] = ->{
      @settings.theme = @rt.string("theme")
      save_settings
    }
    # The modal footer: the clicked label landed in
    # strings["_modal_button"] just before this fires.
    a["confirm"] = ->{
      pending_doc = @pending_close
      @pending_close = nil
      ctx.router.back
      return unless pending_doc
      case @rt.string("_modal_button")
      when "Save"
        save_and_close(pending_doc)
      when "Don't save"
        do_close(pending_doc)
        continue_quit
      else # Cancel
        @quitting = false
      end
    }
  end

  def update(ctx : Egui::Context) : Nil
    ctx.theme = @settings.theme == "Light" ? Egui::Theme.light : Egui::Theme.dark

    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    # Hot reload the markup on external edits (stat-on-frame, the
    # ECSS session pattern). Surviving widget paths keep their state.
    # Debug builds lint the document on load and on every reload —
    # vocabulary drift surfaces in the console, not as a misrender.
    if @exml.reload_if_changed
      lint_exml
    end

    # Publish the model to the store — the markup's only view of the
    # world. Written every frame (a hash write per slot, trivial).
    sync_store(ctx)

    # The whole interface: register the document's pages with the
    # router; the router renders the current route's markup tree.
    @renderer.render_routes(ctx, @exml, @rt)

    # Action dispatch runs last so menu-click re-firings and hotkey
    # presses meet exactly one handler each.
    handle_actions(ctx)
  end

  # Model → store slots. Names are the markup's binding vocabulary:
  # doc_text, selected, no_docs/has_doc, doc_path, dirty_mark, status,
  # show_fps, fps_mark, theme, pending_close, pending_title,
  # confirm_title. (chars/lines are NOT here — the StatusBar component
  # derives them from doc_text.)
  private def sync_store(ctx : Egui::Context) : Nil
    s = @rt.strings
    b = @rt.bools
    doc = @docs[selected]?
    if doc
      s["doc_text"] = doc.text
      s["doc_path"] = doc.path || doc.title
      s["dirty_mark"] = doc.dirty? ? " — modified" : ""
    end
    s["selected"] = selected.to_s
    b["no_docs"] = @docs.empty?
    b["has_doc"] = !@docs.empty?
    s["status"] = @status
    b["show_fps"] = @show_fps
    s["fps_mark"] = @show_fps ? "✓ " : ""
    s["theme"] = @settings.theme
    if (pending = @pending_close)
      b["pending_close"] = true
      s["pending_title"] = pending.title
      s["confirm_title"] = if @quitting
        "Save changes before quitting?"
      else
        "Save changes?"
      end
    else
      b["pending_close"] = false
    end
  end

  # Persist the settings to the user config dir (best effort — the
  # in-memory choice applies regardless).
  private def save_settings : Nil
    Egui::SystemPorts::AppConfig.save("notepad_exml", @settings)
    @status = "Settings saved: #{Egui::SystemPorts::AppConfig.path("notepad_exml")}"
  end

  private def handle_actions(ctx : Egui::Context) : Nil
    new_doc if ctx.consume_action(ACTION_NEW)
    open_doc if ctx.consume_action(ACTION_OPEN)
    save_doc if ctx.consume_action(ACTION_SAVE)
    save_doc_as if ctx.consume_action(ACTION_SAVE_AS)
    close_tab if ctx.consume_action(ACTION_CLOSE) && !@docs.empty?
    quit_flow if ctx.consume_action(ACTION_QUIT)
    next_tab if ctx.consume_action(ACTION_NEXT_TAB)
    previous_tab if ctx.consume_action(ACTION_PREV_TAB)
    ctx.router.navigate("root/settings") if ctx.consume_action(ACTION_SETTINGS)
  end

  private def next_tab : Nil
    return if @docs.size < 2
    self.selected = (selected + 1) % @docs.size
  end

  private def previous_tab : Nil
    return if @docs.size < 2
    self.selected = (selected - 1) % @docs.size
  end

  private def quit_flow : Nil
    dirty = @docs.select(&.dirty?)
    if dirty.empty?
      Egui::SystemPorts::Quit.quit!
    else
      @quitting = true
      @pending_close = dirty.first
      ctx.router.navigate("root/confirm-close")
    end
  end

  private def continue_quit : Nil
    return unless @quitting
    dirty = @docs.select(&.dirty?)
    if dirty.empty?
      Egui::SystemPorts::Quit.quit!
    else
      @pending_close = dirty.first
      ctx.router.navigate("root/confirm-close")
    end
  end

  private def new_doc : Nil
    name = @next_untitled == 2 ? "untitled" : "untitled #{@next_untitled}"
    @next_untitled += 1
    @docs << Doc.new(name: name)
    self.selected = @docs.size - 1
  end

  private def open_doc : Nil
    @status = "Opening dialog…"
    Egui::SystemPorts::OpenFileDialog.show(
      title: "Open text file", filters: [] of String) do |path|
      if path
        begin
          @docs << Doc.new(File.read(path), path: path)
          self.selected = @docs.size - 1
          @status = "Opened: #{path}"
        rescue e : IO::Error | File::Error
          @status = "Cannot read #{path}: #{e.message}"
        end
      else
        @status = "Open canceled."
      end
    end
  end

  private def save_doc : Nil
    doc = @docs[selected]? || return
    if (path = doc.path)
      write_doc(doc, path)
    else
      save_doc_as
    end
  end

  private def save_doc_as : Nil
    doc = @docs[selected]? || return
    default = (p = doc.path) ? File.basename(p) : "#{doc.name}.txt"
    Egui::SystemPorts::SaveFileDialog.show(
      title: "Save as…", default_name: default) do |dest|
      write_doc(doc, dest) if dest
    end
  end

  private def write_doc(doc : Doc, path : String) : Nil
    begin
      File.write(path, doc.text)
      doc.path = path
      doc.dirty = false
      @status = "Saved: #{path}"
    rescue e : IO::Error | File::Error
      @status = "Cannot write #{path}: #{e.message}"
    end
  end

  # --- command-line files ---------------------------------------------

  private def open_at_startup(path : String) : Doc?
    expanded = File.expand_path(path)
    unless File.file?(expanded)
      STDERR.puts "notepad: not a file: #{path}"
      return nil
    end
    unless self.class.text_mime?(expanded)
      STDERR.puts "notepad: not a text file, skipped: #{path}"
      @status = "Skipped #{path} — not a text file."
      return nil
    end
    doc = Doc.new(File.read(expanded), path: expanded)
    @docs << doc
    self.selected = @docs.size - 1
    @status = "Opened: #{expanded}"
    doc
  rescue e : IO::Error | File::Error
    STDERR.puts "notepad: cannot read #{path}: #{e.message}"
    nil
  end

  def self.mime_type(path : String) : String
    outp = IO::Memory.new
    Process.run("file", ["-b", "--mime-type", path],
      output: outp, error: :close)
    mime = outp.to_s.strip
    mime.empty? ? (MIME.from_filename?(path) || "") : mime
  rescue File::Error | IO::Error
    MIME.from_filename?(path) || ""
  end

  def self.text_mime?(path : String) : Bool
    mime = mime_type(path)
    mime.starts_with?("text/") || TEXT_MIME_EXTRAS.includes?(mime)
  end

  private def close_tab : Nil
    request_close(@docs[selected]?)
  end

  private def request_close(doc : Doc?) : Nil
    return unless doc
    return if @pending_close # a confirmation is already on screen
    if doc.dirty?
      @pending_close = doc
      ctx.router.navigate("root/confirm-close")
    else
      do_close(doc)
    end
  end

  private def do_close(doc : Doc) : Nil
    idx = @docs.index(doc) || return
    @docs.delete_at(idx)
    self.selected -= 1 if idx < selected
    self.selected = selected.clamp(0, {@docs.size - 1, 0}.max) unless @docs.empty?
    @status = "Closed: #{doc.title}"
  end

  # "Save" in the confirmation modal: write to the document's file (or
  # ask for one first — the native dialog is async, the close lands in
  # its callback; canceling the dialog keeps the tab open and aborts a
  # pending quit).
  private def save_and_close(doc : Doc) : Nil
    if (path = doc.path)
      write_doc(doc, path)
      do_close(doc)
      continue_quit
    else
      default = "#{doc.name}.txt"
      Egui::SystemPorts::SaveFileDialog.show(
        title: "Save as…", default_name: default) do |dest|
        if dest
          write_doc(doc, dest)
          do_close(doc)
          continue_quit
        else
          @quitting = false
          @status = "Save canceled — the tab stays open."
        end
      end
    end
  end
end

# Entry point: the framework CLI parse pulls --page out of ARGV (in
# place — the file arguments left over go to the app), the router is
# deep-linked before the first frame, and Backend.run does the same
# parse as a no-op fallback for apps that don't do it themselves.
# Skipped whole in embedded builds (see the require guard at the top).
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
app = NotepadExmlApp.new(files, theme)
if (route = cli[:route])
  app.ctx.router.navigate(route)
end
Egui.run(app,
  title: "egui-cr — notepad (exml)", width: 800, height: 600,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64},
  decorations: false, inspector: :hidden)
{% end %}
