require "json"
require "./backend"

# ═══ FRONTEND (notepad) ═══════════════════════════════════════════════
# Вид: вкладки в капшене, меню, per-document textarea, статус-бар,
# страницы root/root | root/settings | root/confirm-close. Ноль файлового
# IO и диалогов — только request. Документы — одноразовый кэш конверта
# (план §7): локальный текст живёт в виджете и коммитится дебаунсом
# (§12: набор → эфемерное состояние, коммит ~200мс → ОДИН request).

class NotepadApp < Egui::App
  # Debug builds keep the inspector's style edits in a `.ecss` diff
  # file next to the binary (style_notepad.ecss) — see src/egui/ecss.cr.
  enable_ecss "notepad"

  # View-cache of a backend Doc: local text (optimistic, debounced
  # commit) + the server's saved_text + the status-bar stats cache.
  class DocView
    getter id : Int64
    getter name : String
    property path : String?
    property text : String
    property saved_text : String

    def initialize(payload : JSON::Any)
      @id = payload["id"].as_i64
      @name = payload["name"].as_s
      @path = payload["path"]?.try(&.as_s?)
      @saved_text = payload["saved_text"].as_s
      # Локальный текст стартует с серверной истины; пока коммит в
      # дебаунсе, локальный набор новее (переносится при патче кэша).
      @text = @saved_text
    end

    def title : String
      (p = @path) ? File.basename(p) : @name
    end

    def dirty? : Bool
      @text != @saved_text
    end

    # Status-bar stats (chars, lines), cached per buffer identity —
    # counting newlines scans the whole buffer (see the original
    # notepad note: a multi-megabyte tab pinned a core).
    @stats_text : String? = nil
    @stats_chars : Int32 = 0
    @stats_lines : Int32 = 1

    def stats : {Int32, Int32}
      unless @stats_text.same?(@text)
        @stats_text = @text
        @stats_chars = @text.size
        @stats_lines = @text.count('\n') + 1
      end
      {@stats_chars, @stats_lines}
    end

    def carry_local_from(other : DocView) : Nil
      # Серверная истина не двигалась — локальный набор (и кэш
      # статистики) пережил круговой рейс нетронутыми.
      return unless other.saved_text == @saved_text
      @text = other.text
      @stats_text = other.@stats_text
      @stats_chars = other.@stats_chars
      @stats_lines = other.@stats_lines
    end
  end

  # The theme dropdown options, in display order.
  THEMES = ["Dark", "Light"]

  @docs = [] of DocView
  getter docs : Array(DocView)
  # The tab selection is a SIGNAL (drives focus-follows-tab; bumped by
  # envelope responses and optimistic tab clicks).
  reactive selected = 0
  @search = ""
  @status = "Ready."
  @hotkeys_ready = false
  # Debounced text commit (§12): due-time + the doc it belongs to.
  @commit_doc_id : Int64? = nil
  @commit_due : Float64? = nil
  # Focus follows the tab: the (selected-version, doc-id) pair the
  # editor focus was last synced to.
  @focused_key : {UInt64, Int64}? = nil
  # The confirmation modal is open (envelope's pending_close).
  @confirm_open = false
  @quitting = false
  # Saved theme choice (settings response cache).
  @theme = "Dark"
  # Debug toggle (Settings → Show FPS).
  @show_fps = false

  def initialize(files : Array(String) = [] of String, theme : String? = nil)
    super()
    # Разводка (до фазы 5 — руками; Egui.run займётся ею с App API).
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(NOTEPAD_ROUTES)
    # Стартовое состояние: настройки (+ разовый override командной
    # строки без записи в конфиг) и стартовые файлы.
    Egui.request "GET", "/settings" do |resp|
      @theme = resp.body["theme"].as_s if resp.ok?
    end
    if theme
      Egui.request "PUT", "/settings", theme: theme, persist: "false" do |resp|
        @theme = resp.body["theme"].as_s if resp.ok?
      end
    end
    unless files.empty?
      Egui.request "POST", "/documents/open_paths", paths: files do |resp|
        apply_envelope(resp)
      end
    end
    refresh

    # Win11 Notepad chrome: the tabs live IN the caption, left of the
    # caption buttons. A tab click writes the selection signal
    # (optimistically) and commits the intention by request; close goes
    # through the same dirty-confirmation flow as Ctrl+W.
    Egui::WindowFrame.caption(
      height: Egui::TitleBarTabs::CAPTION_H) do |ctx, area|
      unless ctx.router.current.page == "settings"
        Egui::TitleBarTabs.show(ctx, area, @docs.map(&.title), selected,
          dirty: @docs.map(&.dirty?),
          on_select: ->(t : Int32) {
            self.selected = t
            send("POST", "/documents/select", index: t)
            nil
          },
          on_close: ->(t : Int32) { close_doc(@docs[t]?) },
          on_new: -> { send("POST", "/documents") })
      end
    end
  end

  # --- транспорт ---------------------------------------------------------

  # Запрос с конверт-патчем: ответ несёт полное состояние приложения,
  # кэш восстанавливается из него между кадрами.
  def send(method : String, path : String, **body) : Nil
    Egui.request(method, path, **body) { |resp| apply_envelope(resp) }
  end

  def refresh : Nil
    send("GET", "/documents")
  end

  # Конверт → кэш: docs пересобираются (локальный текст и статистика
  # переносятся по id, пока серверная истина та же), selected/статус/
  # quitting — напрямую, pending_close управляет роутом модалки.
  def apply_envelope(resp : Egui::Mvc::Response) : Nil
    return unless resp.ok?
    env = resp.body
    old = @docs
    @docs = env["docs"].as_a.map { |d| doc = DocView.new(d); doc }
    @docs.each do |nd|
      old.find { |o| o.id == nd.id }.try { |o| nd.carry_local_from(o) }
    end
    self.selected = env["selected"].as_i
    @status = env["status"].as_s
    @quitting = env["quitting"].as_bool
    # JSON null истинен в Crystal — пустоту проверяем через raw.
    pending = env["pending_close"]
    has_pending = !pending.raw.nil?
    if has_pending && !@confirm_open
      @confirm_open = true
      @pending_id = pending["id"].as_i64
      @pending_title = pending["title"].as_s
      ctx.router.navigate("root/confirm-close")
    elsif !has_pending && @confirm_open
      @confirm_open = false
      ctx.router.back
    elsif has_pending
      @pending_id = pending["id"].as_i64
      @pending_title = pending["title"].as_s
    end
  end

  @pending_id : Int64? = nil
  @pending_title : String? = nil

  def pending_doc : DocView?
    (id = @pending_id) && @docs.find { |d| d.id == id }
  end

  # Коммит правок: textarea зовёт note_edit каждый кадр ввода; уходит
  # ОДИН request через ~200мс тишины (плюс всегда с собой текст несут
  # save/close/confirm — see send_with_text).
  def note_edit(doc : DocView, text : String) : Nil
    doc.text = text
    @commit_doc_id = doc.id
    @commit_due = ctx.input.time + 0.2
  end

  def flush_commit_due(now : Float64) : Nil
    if (due = @commit_due) && now >= due && (id = @commit_doc_id) &&
       (doc = @docs.find { |d| d.id == id })
      @commit_due = nil
      send("PATCH", "/documents/#{id}", text: doc.text)
    end
  end

  # Действия, которым нужен локальный (возможно незакоммиченный) текст.
  def save_doc : Nil
    return unless (doc = @docs[selected]?)
    send("POST", "/documents/#{doc.id}/save", text: doc.text)
  end

  def save_doc_as : Nil
    return unless (doc = @docs[selected]?)
    send("POST", "/documents/#{doc.id}/save_as", text: doc.text)
  end

  def close_doc(doc : DocView?) : Nil
    return unless doc
    send("DELETE", "/documents/#{doc.id}", text: doc.text)
  end

  def confirm(label : String) : Nil
    choice = case label
             when "Save"        then "save"
             when "Don't save"  then "discard"
             else                    "cancel"
             end
    doc = pending_doc
    send("POST", "/app/confirm",
      choice: choice, id: @pending_id, text: doc.try(&.text))
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
    # The theme choice → the live theme (cheap, every frame).
    ctx.theme = @theme == "Light" ? Egui::Theme.light : Egui::Theme.dark

    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    flush_commit_due(ctx.input.time)

    ctx.routes do |r|
      # root/root — the editor: menu bar, per-document textarea (the
      # tabs live in the caption), status bar.
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
            # The editor runs in a child Ui id'd PER DOCUMENT — every
            # tab keeps its own caret and selection across switches.
            doc = @docs[selected]
            rect = ui.allocate_at_least(
              Egui::Vec2.new(ui.available_width, ui.available_height))
            editor = ui.child_ui(rect,
              Egui::Id.from("notepad/doc/#{doc.id}"))
            editor_resp = editor.textarea(doc.text, rows: 100,
              frame: false) { |t| note_edit(doc, t) }

            # ACTIVE TAB = ACTIVE EDITOR, reactively: whenever the
            # selection signal or the selected DOCUMENT changed (click,
            # Ctrl+Tab, open, close), the new tab's textarea takes
            # focus. No per-event plumbing — one place watches the key.
            key = {selected_signal.version, doc.id}
            if key != @focused_key
              @focused_key = key
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
      # button pops the route.
      r.page "root/settings", title: "Settings" do |ui|
        ui.heading("Settings")
        ui.text_edit_singleline(@search, hint: "Search settings…",
          focus_id: "search") { |t| @search = t }
        ui.separator
        ui.label("Theme:")
        # Theme dropdown: swaps the palette next frame; the choice
        # persists through the backend (AppConfig port lives there).
        ui.combo_box("theme", @theme, THEMES) do |name|
          @theme = name
          send("PUT", "/settings", theme: name)
        end
        ui.separator
        ui.label("Editor font size: 14")
        ui.label("Tab width: 4")
        ui.label("This page is a routed page — deep-link with " \
                 "--page root/settings (+#search to focus the search field).")
      end

      # root/confirm-close — unsaved changes. A modal is just a page;
      # its state (pending_close) comes from the envelope.
      if @confirm_open && (ptitle = @pending_title)
        r.modal "root/confirm-close",
          title: @quitting ? "Save changes before quitting?" : "Save changes?",
          buttons: ["Save", "Don't save", "Cancel"],
          on_button: ->(label : String) { confirm(label) } do |ui|
          ui.label("\"#{ptitle}\" has unsaved changes.")
        end
      end
    end

    # Action dispatch runs last so menu-click re-firings and hotkey
    # presses meet exactly one handler each.
    handle_actions(ctx)
  end

  private def handle_actions(ctx : Egui::Context) : Nil
    send("POST", "/documents") if ctx.consume_action(ACTION_NEW)
    send("POST", "/documents/open") if ctx.consume_action(ACTION_OPEN)
    save_doc if ctx.consume_action(ACTION_SAVE)
    save_doc_as if ctx.consume_action(ACTION_SAVE_AS)
    close_tab if ctx.consume_action(ACTION_CLOSE) && !@docs.empty?
    send("POST", "/app/quit") if ctx.consume_action(ACTION_QUIT)
    next_tab if ctx.consume_action(ACTION_NEXT_TAB)
    previous_tab if ctx.consume_action(ACTION_PREV_TAB)
    ctx.router.navigate("root/settings") if ctx.consume_action(ACTION_SETTINGS)
  end

  # Tab cycling (Ctrl+Tab / Ctrl+Shift+Tab): optimistic local switch +
  # намерение бэкенду (владелец selected — бэкенд).
  private def next_tab : Nil
    return if @docs.size < 2
    idx = (selected + 1) % @docs.size
    self.selected = idx
    send("POST", "/documents/select", index: idx)
  end

  private def previous_tab : Nil
    return if @docs.size < 2
    idx = (selected - 1) % @docs.size
    self.selected = idx
    send("POST", "/documents/select", index: idx)
  end

  private def close_tab : Nil
    close_doc(@docs[selected]?)
  end
end
