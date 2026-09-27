# egui-cr notepad — a small tabbed text editor built on the Tabs
# container: a File menu with hotkey hints (New / Open… / Save /
# Save As… / Close Tab / Quit), closable tabs with dirty markers
# ("name *"), a per-document textarea and a status bar. Each tab's
# editor runs in a child Ui id'd per tab, so every document keeps its
# own caret and selection across tab switches; the tab selection is a
# reactive Signal and keyboard focus follows it — the ACTIVE tab's
# textarea is always the active editor. Native open/save dialogs go
# through SystemPorts (fiber-backed, never block frames).

require "mime"

require "../src/egui"
require "../src/egui/backend/sokol"

class NotepadApp < Egui::App
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

    def initialize(@text : String = "", @path : String? = nil,
                   @name : String = "untitled")
    end

    # Tab title: file name (or the untitled name), "*" while unsaved
    # edits exist.
    def title : String
      base = (p = @path) ? File.basename(p) : @name
      @dirty ? "#{base} *" : base
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

  def initialize
    super
    # Files passed on the command line open straight into tabs.
    opened = 0
    ARGV.each do |arg|
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

  DEFAULT_BINDINGS = {
    ACTION_NEW      => "Ctrl+N",
    ACTION_OPEN     => "Ctrl+O",
    ACTION_SAVE     => "Ctrl+S",
    ACTION_SAVE_AS  => "Ctrl+Shift+S",
    ACTION_CLOSE    => "Ctrl+W",
    ACTION_QUIT     => "Ctrl+Q",
    ACTION_NEXT_TAB => "Ctrl+Tab",
    ACTION_PREV_TAB => "Ctrl+Shift+Tab",
  }

  def update(ctx : Egui::Context) : Nil
    # Default hotkey bindings — once, on the first frame.
    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

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
    end

    ctx.central_panel do |ui|
      if @docs.empty?
        ui.label("No documents open — File → New (Ctrl+N).")
      else
        # The tab strip claims the top row; the cursor is left below it.
        # A tab click WRITES the selection signal (the focus sync below
        # reacts to its version).
        ui.tabs(@docs.map(&.title), selected, closable: true,
          on_close: ->(t : Int32) { request_close(@docs[t]?) }) do |t|
          self.selected = t
        end

        # Claim the rest of the panel, then run the editor in a child
        # Ui id'd per tab — each document keeps its own caret and
        # selection (TextArea state lives under the widget id).
        doc = @docs[selected]
        rect = ui.allocate_at_least(
          Egui::Vec2.new(ui.available_width, ui.available_height))
        editor = ui.child_ui(rect, editor_ui_id)
        editor_resp = editor.textarea(doc.text, rows: 100) do |t|
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

    # Unsaved-changes confirmation for a pending close (or the quit
    # cascade) — the modal blocks everything below until one of the
    # three is picked.
    if (doc = @pending_close)
      ctx.modal("confirm_close") do |ui|
        ui.heading(@quitting ? "Save changes before quitting?" : "Save changes?")
        ui.label("\"#{doc.title}\" has unsaved changes.")
        ui.horizontal do |row|
          if row.button("Save").clicked?
            @pending_close = nil
            save_and_close(doc)
          end
          if row.button("Don't save").clicked?
            @pending_close = nil
            do_close(doc)
            continue_quit
          end
          if row.button("Cancel").clicked?
            @pending_close = nil
            @quitting = false
          end
        end
      end
    end

    ctx.bottom_panel("status") do |ui|
      if (doc = @docs[selected]?)
        ui.label("#{doc.path || doc.title} — #{doc.text.size} chars, " \
                 "#{doc.text.count('\n') + 1} lines" \
                 "#{doc.dirty? ? " — modified" : ""}")
      end
      ui.label(@status)
    end

    # Action dispatch runs last so menu-click re-firings and hotkey
    # presses meet exactly one handler each.
    handle_actions(ctx)
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

Egui::Backend::Sokol.run(NotepadApp.new,
  title: "egui-cr — notepad", width: 800, height: 600)
