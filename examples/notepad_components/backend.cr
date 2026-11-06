require "../../src/egui"
require "mime"
require "json"

# ═══ BACKEND ПРИЛОЖЕНИЯ (notepad) ════════════════════════════════════
# MVC-разрез (plans/frontend-backend-split.md фаза 4; анализ —
# plans/mvc-examples-analysis.md §notepad): Document — CRUD-ресурс,
# DocumentsController — create/open/update/save/save_as/destroy +
# confirm-close-цепочка и quit-флоу, SettingsController — AppConfig-
# персист. Файлы, диалоги и MIME-сниффинг — «как достать» — живут
# здесь; фронт остаётся без файлов и диалогов (§2). Файл driver-free:
# его гоняют и пример, и спеки.
#
# Конверт: каждый ответ несёт ПОЛНОЕ состояние приложения (docs/
# selected/pending_close/quitting/status) — временная замена State
# (фаза 5): фронтендный кэш можно выкинуть и восстановить из ответа.
# Модель чистоты: Doc.text — закоммиченный текст, Doc.saved_text —
# файловая истина; dirty = text != saved_text (на сервере; фронт
# считает локальный dirty по тому же правилу против saved_text из
# конверта, пока коммит в дебаунсе).
#
# Диалоги: нативные Show/SaveFileDialog — fiber-backed (колбэк между
# кадрами); действие контроллера ПАРКУЕТ запрос на Channel.receive,
# живя в собственном файбере транспорта, — ответ приезжает, когда
# юзер выбрал файл. Блокирует только свой файбер, не кадр.

class NotepadBackend
  # Persisted settings (the AppConfig system port).
  class Settings
    include JSON::Serializable

    property theme : String = "Dark"

    def initialize(@theme : String = "Dark")
    end
  end

  # One open document: text = committed edits, saved_text = the file's
  # content (or the seed content of an untitled doc), path = where it
  # came from (nil = never saved).
  class Doc
    property text : String
    property saved_text : String
    property path : String?
    getter id : Int64
    getter name : String

    def initialize(@id : Int64, @text : String, @path : String?,
                   @name : String, saved_text : String? = nil)
      @saved_text = saved_text || @text
    end

    def title : String
      (p = @path) ? File.basename(p) : @name
    end

    def dirty? : Bool
      @text != @saved_text
    end
  end

  # MIME types that count as "text" beyond the text/* family.
  TEXT_MIME_EXTRAS = {"application/json", "application/xml",
                      "application/yaml", "application/x-yaml",
                      "application/toml", "application/javascript"}

  WELCOME = "Welcome to egui-cr notepad!\n" \
            "\n" \
            "Ctrl+N — new tab, Ctrl+O — open a file, Ctrl+S — save.\n" \
            "Each tab keeps its own caret and selection.\n"

  @@docs = [] of Doc
  @@next_id = 1_i64
  @@next_untitled = 1
  @@selected = 0
  @@pending_close : Doc? = nil
  @@quitting = false
  @@status = "Ready."
  @@settings = Settings.new

  def self.reset! : Nil
    @@docs = [Doc.new(@@next_id, WELCOME, nil, "untitled")]
    @@next_id = 2_i64
    @@next_untitled = 1
    @@selected = 0
    @@pending_close = nil
    @@quitting = false
    @@status = "Ready."
    @@settings = Settings.new
  end

  # Ленивый сидинг: прод стартует с welcome-табом; спеки зовут reset!.
  def self.docs : Array(Doc)
    reset! if @@docs.empty? && @@next_id == 1
    @@docs
  end

  def self.find(id : Int64) : Doc?
    docs.find { |d| d.id == id }
  end

  def self.selected : Int32
    @@selected
  end

  def self.selected=(index : Int32) : Nil
    @@selected = index.clamp(0, {docs.size - 1, 0}.max)
  end

  def self.settings : Settings
    @@settings
  end

  def self.status=(message : String) : Nil
    @@status = message
  end

  def self.load_settings : Nil
    @@settings = Egui::SystemPorts::AppConfig.load("notepad", Settings.new)
  end

  def self.save_settings : Nil
    Egui::SystemPorts::AppConfig.save("notepad", @@settings)
  end

  # --- конверт -----------------------------------------------------------

  def self.envelope
    {
      "docs" => docs.map { |d|
        {"id" => d.id, "title" => d.title, "path" => d.path,
         "name" => d.name, "saved_text" => d.saved_text}
      },
      "selected"      => @@selected,
      "pending_close" => (doc = @@pending_close) ?
                           {"id" => doc.id, "title" => doc.title} : nil,
      "quitting"      => @@quitting,
      "status"        => @@status,
    }
  end

  # --- действия над документами ------------------------------------------

  # File → New.
  def self.create! : Nil
    name = @@next_untitled == 2 ? "untitled" : "untitled #{@@next_untitled}"
    @@next_untitled += 1
    @@docs << Doc.new(@@next_id, "", nil, name)
    @@next_id += 1
    @@selected = @@docs.size - 1
  end

  def self.select!(index : Int32) : Nil
    self.selected = index
  end

  # Коммит правок (дебаунс на фронте, план §12).
  def self.update!(id : Int64, text : String) : Nil
    find(id).try { |doc| doc.text = text }
  end

  # File → Open… по выбранному в диалоге пути.
  def self.open_file!(path : String) : Nil
    begin
      content = File.read(path)
      @@docs << Doc.new(@@next_id, content, path, File.basename(path))
      @@next_id += 1
      @@selected = @@docs.size - 1
      @@status = "Opened: #{path}"
    rescue e : IO::Error | File::Error
      @@status = "Cannot read #{path}: #{e.message}"
    end
  end

  # Стартовые файлы командной строки: валидация (файл? текстовый MIME?),
  # welcome-таб исчезает, если хоть один открылся.
  def self.open_paths!(paths : Array(String)) : Nil
    opened = 0
    paths.each do |path|
      expanded = File.expand_path(path)
      unless File.file?(expanded)
        STDERR.puts "notepad: not a file: #{path}"
        next
      end
      unless text_mime?(expanded)
        STDERR.puts "notepad: not a text file, skipped: #{path}"
        @@status = "Skipped #{path} — not a text file."
        next
      end
      open_file!(expanded)
      opened += 1
    end
    if opened > 0 && @@docs.size > 1
      @@docs.shift
      @@selected = @@docs.size - 1
    end
  end

  # Сохранение по известному пути.
  def self.save_text!(id : Int64, text : String) : Bool
    return false unless (doc = find(id)) && (path = doc.path)
    write(doc, text, path)
  end

  # Save As: дописывает по выбранному адресу и усыновляет путь.
  def self.save_as!(id : Int64, text : String, dest : String) : Nil
    return unless (doc = find(id))
    write(doc, text, dest)
    doc.path = dest if doc.saved_text == text
  end

  private def self.write(doc : Doc, text : String, path : String) : Bool
    begin
      File.write(path, text)
      doc.text = text
      doc.saved_text = text
      @@status = "Saved: #{path}"
      true
    rescue e : IO::Error | File::Error
      @@status = "Cannot write #{path}: #{e.message}"
      false
    end
  end

  def self.needs_dialog?(id : Int64) : Bool
    find(id).try(&.path.nil?) || false
  end

  def self.default_save_name(id : Int64) : String
    return "untitled.txt" unless (doc = find(id))
    (p = doc.path) ? File.basename(p) : "#{doc.name}.txt"
  end

  # --- закрытие / квит ---------------------------------------------------

  # Запрос закрытия: чистый закрывается сразу; dirty → pending_close
  # (конверт несёт его — фронт рисует модалку). text — локальный
  # (незакоммиченный) текст, приезжает вместе с намерением.
  def self.request_close!(id : Int64, text : String?) : Nil
    return unless (doc = find(id))
    doc.text = text if text
    if doc.dirty?
      return if @@pending_close # подтверждение уже на экране
      @@pending_close = doc
    else
      close!(doc)
    end
  end

  # Quit flow: чистое состояние уходит сразу; dirty — по одному через
  # подтверждение.
  def self.quit! : Nil
    dirty = docs.select(&.dirty?)
    if dirty.empty?
      Egui::SystemPorts::Quit.quit!
      @@status = "Quitting."
    else
      @@quitting = true
      @@pending_close = dirty.first
    end
  end

  # Кнопка модалки: Save / Don't save / Cancel. При Save без пути адрес
  # выбирается диалогом — контроллер резолвит его ДО вызова (запрос
  # парковался) и передаёт сюда; отмена диалога = cancel.
  def self.confirm!(choice : String, id : Int64?, text : String?,
                    dest : String?) : Nil
    doc = (@@pending_close ||= id ? find(id.not_nil!) : nil)
    return unless doc
    case choice
    when "save"
      doc.text = text if text
      if dest
        save_as!(doc.id, doc.text, dest)
        close_and_continue(doc)
      elsif (path = doc.path)
        save_text!(doc.id, doc.text)
        close_and_continue(doc)
      else
        @@pending_close = nil
        @@quitting = false
        @@status = "Save canceled — the tab stays open."
      end
    when "discard"
      @@pending_close = nil
      close_and_continue(doc)
    else # cancel
      @@pending_close = nil
      @@quitting = false
      @@status = "Close canceled."
    end
  end

  def self.close_and_continue(doc : Doc) : Nil
    close!(doc)
    return unless @@quitting
    dirty = @@docs.select(&.dirty?)
    if dirty.empty?
      @@quitting = false
      Egui::SystemPorts::Quit.quit!
      @@status = "Quitting."
    else
      @@pending_close = dirty.first
    end
  end

  def self.close!(doc : Doc) : Nil
    idx = @@docs.index(doc) || return
    @@docs.delete_at(idx)
    @@selected -= 1 if idx < @@selected
    @@selected = @@selected.clamp(0, {@@docs.size - 1, 0}.max) unless @@docs.empty?
    @@status = "Closed: #{doc.title}"
  end

  # Real content sniffing through file(1), with the extension registry
  # (stdlib MIME) as the fallback where file(1) is missing (Windows).
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
end

# Диалоговый ввод-вывод за транспортом: паркует ТЕКУЩИЙ файбер на
# Channel.receive, пока нативный диалог не ответит (колбэк приезжает
# между кадрами — см. AsyncDialogs; файбер запроса живёт у транспорта).
module NotepadDialogs
  def self.open_path : String?
    chan = Channel(String?).new
    Egui::SystemPorts::OpenFileDialog.show(
      title: "Open text file", filters: [] of String) do |path|
      chan.send(path)
    end
    chan.receive
  end

  def self.save_dest(default : String) : String?
    chan = Channel(String?).new
    Egui::SystemPorts::SaveFileDialog.show(
      title: "Save as…", default_name: default) do |dest|
      chan.send(dest)
    end
    chan.receive
  end
end

# --- Контроллеры -----------------------------------------------------------
# Тонкие: вся логика в NotepadBackend (инстанс контроллера живёт один
# запрос — состояние только в бэкенде). Никаких методов с не-request
# арностью: actions-макрос диспатчит КАЖДЫЙ метод класса как экшен.

class DocumentsController < Egui::Mvc::Controller
  # GET /documents — конверт.
  def index(request)
    NotepadBackend.envelope
  end

  # POST /documents — File → New.
  def create(request)
    NotepadBackend.create!
    NotepadBackend.envelope
  end

  # POST /documents/select — выбор вкладки (метод не зовётся `select`:
  # это ключевое слово Crystal и actions-макрос его не диспатчит).
  def pick(request)
    NotepadBackend.select!(request.body["index"]?.try(&.as_i) || 0)
    NotepadBackend.envelope
  end

  # POST /documents/open — нативный диалог, затем новый таб.
  def open(request)
    case path = NotepadDialogs.open_path
    when String then NotepadBackend.open_file!(path)
    else
      NotepadBackend.status = "Open canceled."
    end
    NotepadBackend.envelope
  end

  # POST /documents/open_paths — стартовые файлы командной строки.
  def open_paths(request)
    paths = (request.body["paths"]? ||
             JSON::Any.new([] of JSON::Any)).as_a.map(&.as_s)
    NotepadBackend.open_paths!(paths)
    NotepadBackend.envelope
  end

  # PATCH /documents/:id — коммит правок (дебаунс на фронте, §12).
  def update(request)
    NotepadBackend.update!(request.params["id"].to_i64,
      request.body["text"]?.try(&.as_s) || "")
    NotepadBackend.envelope
  end

  # POST /documents/:id/save — Ctrl+S (без пути — сначала диалог).
  def save(request)
    id = request.params["id"].to_i64
    text = request.body["text"]?.try(&.as_s) || ""
    if NotepadBackend.needs_dialog?(id)
      if (dest = NotepadDialogs.save_dest(NotepadBackend.default_save_name(id)))
        NotepadBackend.save_as!(id, text, dest)
      else
        NotepadBackend.status = "Save canceled."
      end
    else
      NotepadBackend.save_text!(id, text)
    end
    NotepadBackend.envelope
  end

  # POST /documents/:id/save_as — Save As… (всегда диалог).
  def save_as(request)
    id = request.params["id"].to_i64
    text = request.body["text"]?.try(&.as_s) || ""
    if (dest = NotepadDialogs.save_dest(NotepadBackend.default_save_name(id)))
      NotepadBackend.save_as!(id, text, dest)
    else
      NotepadBackend.status = "Save canceled."
    end
    NotepadBackend.envelope
  end

  # DELETE /documents/:id — Close Tab: dirty → pending_close (модалка —
  # это флоу, а не конфликт: конверт несёт pending_close).
  def destroy(request)
    NotepadBackend.request_close!(request.params["id"].to_i64,
      request.body["text"]?.try(&.as_s?))
    NotepadBackend.envelope
  end

  # POST /app/quit — квит-флоу.
  def quit(request)
    NotepadBackend.quit!
    NotepadBackend.envelope
  end

  # POST /app/confirm — кнопка модалки; save без пути резолвит адрес
  # диалогом (запрос запаркован), отмена диалога = cancel.
  def confirm(request)
    choice = request.body["choice"]?.try(&.as_s) || "cancel"
    id = request.body["id"]?.try(&.as_i64)
    text = request.body["text"]?.try(&.as_s)
    dest = nil
    if choice == "save" && id && NotepadBackend.needs_dialog?(id.to_i64)
      dest = NotepadDialogs.save_dest(NotepadBackend.default_save_name(id.to_i64))
      choice = "cancel" unless dest # диалог закрыт — таб остаётся
    end
    NotepadBackend.confirm!(choice, id, text, dest)
    NotepadBackend.envelope
  end

  actions
end

class SettingsController < Egui::Mvc::Controller
  # GET /settings — текущие настройки.
  def show(request)
    {"theme" => NotepadBackend.settings.theme}
  end

  # PUT /settings — тема (persist=false: разовый override командной
  # строки, без записи в конфиг).
  def update(request)
    theme = request.body["theme"]?.try(&.as_s) || "Dark"
    persist = request.body["persist"]?.try(&.as_s?) != "false"
    NotepadBackend.settings.theme = theme
    if persist
      NotepadBackend.save_settings
      NotepadBackend.status =
        "Settings saved: #{Egui::SystemPorts::AppConfig.path("notepad")}"
    end
    {"theme" => NotepadBackend.settings.theme}
  end

  actions
end

NOTEPAD_ROUTES = Egui::Mvc::Router.new.draw do |r|
  r.get "/documents", DocumentsController, "index"
  r.post "/documents", DocumentsController, "create"
  r.post "/documents/select", DocumentsController, "pick"
  r.post "/documents/open", DocumentsController, "open"
  r.post "/documents/open_paths", DocumentsController, "open_paths"
  r.patch "/documents/:id", DocumentsController, "update"
  r.post "/documents/:id/save", DocumentsController, "save"
  r.post "/documents/:id/save_as", DocumentsController, "save_as"
  r.delete "/documents/:id", DocumentsController, "destroy"
  r.post "/app/quit", DocumentsController, "quit"
  r.post "/app/confirm", DocumentsController, "confirm"
  r.get "/settings", SettingsController, "show"
  r.put "/settings", SettingsController, "update"
end
