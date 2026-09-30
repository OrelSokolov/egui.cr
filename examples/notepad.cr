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
# child Ui id'd per tab, so every document keeps its own caret and
# selection across tab switches; the tab selection is a reactive
# Signal and keyboard focus follows it — the ACTIVE tab's textarea is
# always the active editor. Native open/save dialogs go through
# SystemPorts (fiber-backed, never block frames). The theme choice on
# the settings page persists as JSON through the AppConfig system port.

require "json"
require "mime"

require "./icon" # ICON_64_RGBA — the shared app icon (64x64 RGBA)
require "../src/egui"
require "../src/egui/backend/sokol"

class NotepadApp < Egui::App
  # Persisted settings (the AppConfig system port): stored as JSON in
  # the user config dir (~/.config/notepad/settings.json et al.) and
  # reloaded on start. A missing or corrupt file yields the defaults.
  class Settings
    include JSON::Serializable

    property theme : String = "Dark"

    def initialize(@theme : String = "Dark")
    end
  end

  # The theme dropdown options, in display order.
  THEMES = ["Dark", "Light"]

  # MIME types that count as "text" beyond the text/* family (config
  # and data formats people edit in a notepad).
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
    # Status-bar stats (chars, lines), cached per buffer identity —
    # counting newlines scans the whole buffer, and the status bar
    # used to do it EVERY FRAME (a multi-megabyte tab pinned a core).
    # Edits assign a new String, so identity says when to recompute.
    @stats_text : String? = nil
    @stats_chars : Int32 = 0
    @stats_lines : Int32 = 1

    def initialize(@text : String = "", @path : String? = nil,
                   @name : String = "untitled")
    end

    # Tab title: the file name (or the untitled name) — the dirty
    # marker is the Notepad dot, drawn by TitleBarTabs (dirty:).
    def title : String
      (p = @path) ? File.basename(p) : @name
    end

    def stats : {Int32, Int32}
      unless @stats_text.same?(@text)
        @stats_text = @text
        @stats_chars = @text.size
        @stats_lines = @text.count('\n') + 1
      end
      {@stats_chars, @stats_lines}
    end
  end

  @docs = [Doc.new(
    "Welcome to egui-cr notepad!\n" \
    "\n" \
    "Ctrl+N — new tab, Ctrl+O — open a file, Ctrl+S — save.\n" \
    "Each tab keeps its own caret and selection.\n")]
  # The tab selection is a SIGNAL: every switch (tab click, Ctrl+Tab,
  # open, close) bumps its version — the focus-follows-tab sync below
  # is driven by that version, not by per-event plumbing. Out-of-frame
  # writes (dialog callbacks) request a repaint via the setter.
  reactive selected = 0
  # The active editor's child-Ui id, derived from the selection
  # (memoized — recomputed only when `selected` actually changes).
  computed editor_ui_id : Egui::Id = Egui::Id.from("notepad/doc/#{selected}")
  # In-app ROUTE (Win11 Notepad idiom): the settings page and the
  # unsaved-changes confirmation are routed PAGES (Egui::Router) —
  # root/root is the editor, root/settings the full-window settings
  # page, root/confirm-close the confirmation (a modal page). The
  # router owns navigation; deep links work: --page root/settings.
  @search = ""
  @status = "Ready."
  @hotkeys_ready = false
  @next_untitled = 1
  # Which `selected`-signal version the editor focus was last synced
  # to (UInt64::MAX = never — the first frame focuses the active tab).
  @focused_tab_version : UInt64 = UInt64::MAX
  # A dirty document awaiting the Save / Don't save / Cancel choice
  # (the confirmation modal is open for it).
  @pending_close : Doc? = nil
  # Quit is running: confirm every dirty document, then really quit.
  @quitting = false
  # Debug toggle (Settings → Show FPS): while on, the status bar shows
  # the smoothed FPS from ctx.fps.
  @show_fps = false
  # Saved settings — theme choice, persisted through AppConfig.
  @settings : Settings = Egui::SystemPorts::AppConfig.load(
    "notepad", Settings.new)

  def initialize(files : Array(String) = [] of String, theme : String? = nil)
    super()
    # Screenshot/theme override: `notepad --theme Light file.txt` forces
    # the palette for this run without touching the saved settings.
    @settings.theme = theme if theme
    # Win11 Notepad chrome: the tabs live IN the caption, left of the
    # caption buttons (WindowFrame draws the hook before app frames).
    # A tab click writes the selection signal; close goes through the
    # same dirty-confirmation flow as Ctrl+W; "+" is File → New.
    Egui::WindowFrame.caption(
      height: Egui::TitleBarTabs::CAPTION_H) do |ctx, area|
      # No tabs on the settings page (Win11 Notepad hides them there) —
      # the caption keeps only its drag strip and control buttons.
      unless ctx.router.current.page == "settings"
        Egui::TitleBarTabs.show(ctx, area, @docs.map(&.title), selected,
          dirty: @docs.map(&.dirty?),
          on_select: ->(t : Int32) { self.selected = t; nil },
          on_close: ->(t : Int32) { request_close(@docs[t]?) },
          on_new: -> { new_doc })
      end
    end
    # Files passed on the command line open straight into tabs (the
    # framework --page flag is already extracted — see the entry point
    # at the bottom of this file).
    opened = 0
    files.each do |arg|
      opened += 1 if open_at_startup(arg)
    end
    # Command-line files make the pristine welcome tab redundant.
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

  def update(ctx : Egui::Context) : Nil
    # The saved theme choice → the live theme (cheap, every frame, so
    # the swap from the settings dropdown shows immediately — a no-op
    # while the choice hasn't changed, see Context#theme=).
    ctx.theme = @settings.theme == "Light" ? Egui::Theme.light : Egui::Theme.dark

    # Default hotkey bindings — once, on the first frame.
    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    # ROUTES: the editor (root/root), the settings page (root/settings)
    # and the unsaved-changes confirmation (root/confirm-close, a modal
    # page over the editor). The router renders the current stack; back
    # buttons pop it.
    ctx.routes do |r|
      # root/root — the editor: menu bar, per-document textarea
      # (the tabs live in the caption), status bar.
      r.page "root/root" do
        ctx.menu_bar do |bar|
          bar.menu_button("File") do |menu|
            menu.menu_item("New", ACTION_NEW)
            menu.menu_item("Open…", ACTION_OPEN)
            menu.menu_item("Save", ACTION_SAVE)
            menu.menu_item("Save As…", ACTION_SAVE_AS)
            menu.menu_item("Close Tab", ACTION_CLOSE)
            menu.menu_item("Quit", ACTION_QUIT)
          end
          bar.menu_button("View") do |menu|
            menu.menu_item("Next Tab", ACTION_NEXT_TAB)
            menu.menu_item("Previous Tab", ACTION_PREV_TAB)
          end
          # Settings is a section of its own, not a File entry — it's a
          # page navigation, not a document operation.
          bar.menu_button("Settings") do |menu|
            menu.menu_item("Settings…", ACTION_SETTINGS)
            menu.menu_item("#{@show_fps ? "✓ " : ""}Show FPS") do
              @show_fps = !@show_fps
            end
          end
        end

        ctx.central_panel do |ui|
          if @docs.empty?
            ui.label("No documents open — File → New (Ctrl+N), or the " \
                     "\"+\" in the title bar.")
          else
            # Claim the rest of the panel, then run the editor in a child
            # Ui id'd per tab — each document keeps its own caret and
            # selection (TextArea state lives under the widget id).
            doc = @docs[selected]
            rect = ui.allocate_at_least(
              Egui::Vec2.new(ui.available_width, ui.available_height))
            editor = ui.child_ui(rect, editor_ui_id)
            editor_resp = editor.textarea(doc.text, rows: 100,
              frame: false) do |t|
              doc.text = t
              doc.dirty = true
            end

            # ACTIVE TAB = ACTIVE EDITOR, reactively: whenever the
            # selection signal moved (any path — click, Ctrl+Tab, open,
            # close), the new tab's textarea takes keyboard focus (a focus
            # request lands next frame, like every focus change). No
            # per-event plumbing — one place watches the signal version.
            if selected_signal.version != @focused_tab_version
              @focused_tab_version = selected_signal.version
              ctx.memory.focus.request(editor_resp.id)
            end
          end
        end

        ctx.bottom_panel("status") do |ui|
          if (doc = @docs[selected]?)
            chars, lines = doc.stats
            ui.label("#{doc.path || doc.title} — #{chars} chars, #{lines} lines" \
                     "#{doc.dirty? ? " — modified" : ""}")
          end
          ui.label(@status)
          # A live meter needs live frames: with on-demand repaint an
          # idle app would freeze at the last reading.
          if @show_fps
            ctx.request_repaint
            ui.label("FPS: #{"%.1f" % ctx.fps}  " \
                     "(frame #{"%.1f" % (ctx.input.dt * 1000)} ms)")
          end
        end
      end

      # root/settings — the full-window settings page; the round back
      # button pops the route. The search field's focus_id makes
      # `--page root/settings#search` land the caret in it.
      r.page "root/settings", title: "Settings" do |ui|
        ui.heading("Settings")
        ui.text_edit_singleline(@search, hint: "Search settings…",
          focus_id: "search") { |t| @search = t }
        ui.separator
        ui.label("Theme:")
        # Theme dropdown: swaps the palette next frame and persists the
        # choice to the user config dir.
        ui.combo_box("theme", @settings.theme, THEMES) do |name|
          @settings.theme = name
          save_settings
        end
        ui.separator
        ui.label("Editor font size: 14")
        ui.label("Tab width: 4")
        ui.label("This page is a routed page — deep-link with " \
                 "--page root/settings (+#search to focus the search field).")
      end

      # root/confirm-close — unsaved changes. A modal is just a page:
      # an addressable overlay route, semi-transparent over the editor.
      # Declared only while a confirmation is pending, so a deep link
      # to it without one lands on the soft not-found page.
      # (The local is NOT named `doc` on purpose: a same-named local in
      # this scope and in the editor's central-panel closure trips a
      # Crystal 1.21 closure-env bug — the on-change proc then sees a
      # nil Doc and typing segfaults.)
      if @pending_close
        pending_doc = @pending_close.not_nil!
        r.modal "root/confirm-close",
          title: @quitting ? "Save changes before quitting?" : "Save changes?" do |ui|
          ui.label("\"#{pending_doc.title}\" has unsaved changes.")
          ui.separator
          ui.horizontal do |row|
            if row.button("Save").clicked?
              @pending_close = nil
              ctx.router.back
              save_and_close(pending_doc)
            elsif row.button("Don't save").clicked?
              @pending_close = nil
              ctx.router.back
              do_close(pending_doc)
              continue_quit
            elsif row.button("Cancel").clicked?
              @pending_close = nil
              ctx.router.back
              @quitting = false
            end
          end
        end
      end
    end

    # Action dispatch runs last so menu-click re-firings and hotkey
    # presses meet exactly one handler each.
    handle_actions(ctx)
  end

  # Persist the settings to the user config dir (best effort — the
  # in-memory choice applies regardless).
  private def save_settings : Nil
    Egui::SystemPorts::AppConfig.save("notepad", @settings)
    @status = "Settings saved: #{Egui::SystemPorts::AppConfig.path("notepad")}"
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

  # Tab cycling (Ctrl+Tab / Ctrl+Shift+Tab): wrap around the open
  # documents, carousel keeps the new active tab on screen.
  private def next_tab : Nil
    return if @docs.size < 2
    self.selected = (selected + 1) % @docs.size
  end

  private def previous_tab : Nil
    return if @docs.size < 2
    self.selected = (selected - 1) % @docs.size
  end

  # Quit flow: clean state quits at once; dirty documents get the
  # Save / Don't save / Cancel modal one by one, then the app quits.
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

  # After a document was closed by the confirmation modal: either move
  # on to the next dirty one or finish the pending quit.
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

  # File → New: append a fresh untitled document and select it.
  private def new_doc : Nil
    name = @next_untitled == 2 ? "untitled" : "untitled #{@next_untitled}"
    @next_untitled += 1
    @docs << Doc.new(name: name)
    self.selected = @docs.size - 1
  end

  # File → Open…: native dialog, then a new tab with the file's text.
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

  # File → Save: write to the document's file, or ask for one first.
  private def save_doc : Nil
    doc = @docs[selected]? || return
    if (path = doc.path)
      write_doc(doc, path)
    else
      save_doc_as
    end
  end

  # File → Save As…: native dialog, then write (and adopt the target).
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

  # --- command-line files ------------------------------------------

  # Open one startup argument into a tab; nil (with a stderr note)
  # when it is missing or not a text file.
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

  # Real content sniffing through file(1) (`file -b --mime-type`),
  # with the extension registry (stdlib MIME) as the fallback where
  # file(1) is missing (Windows).
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

  # Close flow: a clean document closes at once; a dirty one gets the
  # Save / Don't save / Cancel modal first (identity, not index — the
  # document list can shift while a native dialog is open).
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
Egui::Backend::Sokol.run(app,
  title: "egui-cr — notepad", width: 800, height: 600,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64},
  decorations: false, inspector: :hidden)
