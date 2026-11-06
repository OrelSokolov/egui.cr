require "../../src/egui"

# ═══ BACKEND ПРИЛОЖЕНИЯ (terminal) ═══════════════════════════════════
# MVC-разрез (plans/frontend-backend-split.md фаза 4; анализ —
# plans/mvc-examples-analysis.md §terminal). Контрольная плоскость
# сессий — через контроллер (как камера в §4.1): open/close/stdin-
#намерения, копипаст (clipboard-порт за границей), репа мёртвых детей
# и выход с последней вкладкой. Сами PTY-сессии — порт-объекты на
# полке TerminalRepo: TermView (виджет фреймворка) держит их по
# ссылке и кормит вводом напрямую — скроллбэк НЕ стрим (§4.1), это
# состояние сессии. Структурные слайсы (список табов, selected,
# профили) едут через State; фронт читает их как StateView и
# подписывается (подписка = repaint).
#
# Файл driver-free; фейк-фабрика сессий — спековый шов (нативная
# Egui::Terminal::Session требует PTY-шим, его ставит точка входа).

class TerminalRepo
  # Полка порт-объектов: id → сессия. Фронт берёт сюда по id для
  # TermView (то же исключение, что FrameStream у камеры: объект порта
  # живёт по ссылке у обоих слоёв).
  @@sessions = {} of Int64 => Egui::Terminal::Backend
  @@order = [] of Int64
  @@next_id = 1_i64
  @@selected = 0
  @@config : Egui::Terminal::Config? = nil
  # Фабрика сессий: прод ставит нативную PTY, спеки — фейк.
  class_property session_factory : (String?, Proc(Nil) -> Egui::Terminal::Backend)?

  def self.sessions : Hash(Int64, Egui::Terminal::Backend)
    @@sessions
  end

  def self.session(id : Int64) : Egui::Terminal::Backend?
    @@sessions[id]?
  end

  def self.config : Egui::Terminal::Config
    (@@config ||= Egui::Terminal::Config.load)
  end

  def self.reset! : Nil
    @@sessions.each_value(&.close)
    @@sessions.clear
    @@order.clear
    @@next_id = 1_i64
    @@selected = 0
    @@config = Egui::Terminal::Config.new
    wire
  end

  # Слайсы стора: структура табов и профили. Регистрируется на
  # Egui::Mvc.state (интерим-разводка; App API §12 раздаст адресно).
  def self.wire : Nil
    Egui::Mvc.state.on("terminal/sync") do |payload, w|
      w.set("terminal/tabs", payload["tabs"])
      w.set("terminal/selected", payload["selected"])
    end
    Egui::Mvc.state.on("terminal/profiles") do |payload, w|
      w.set("terminal/profiles", payload)
    end
  end

  def self.sync! : Nil
    Egui::Mvc.state.dispatch("terminal/sync", Egui::Mvc.to_json_any({
      "tabs"     => @@order,
      "selected" => @@selected,
    }))
  end

  def self.sync_profiles! : Nil
    p = config.active_profile
    bg = p.background_color
    Egui::Mvc.state.dispatch("terminal/profiles", Egui::Mvc.to_json_any({
      "names"    => config.profiles.keys,
      "active"   => config.active,
      "opacity"  => p.opacity,
      "bg"       => {bg.r, bg.g, bg.b},
      "blink"    => p.cursor_blinks,
    }))
  end

  def self.boot! : Nil
    wire
    sync!
    sync_profiles!
  end

  # --- сессии -------------------------------------------------------------

  # Wake-хук PTY-ридера: данные приехали → разбудить кадр (проекция
  # стора в отрисовку) и заодно прорепать мёртвых (смерть часто
  # приходит последним куском вывода).
  def self.wake_proc : Proc(Nil)
    -> do
      reap!
      Egui::Driver::Base.current.try &.wake
    end
  end

  def self.open!(cwd : String? = nil) : Int64
    factory = (TerminalRepo.session_factory ||
               raise "set TerminalRepo.session_factory (the entry point installs the PTY one)")
    id = @@next_id
    @@next_id += 1
    @@sessions[id] = factory.call(cwd, wake_proc)
    @@order << id
    @@selected = @@order.size - 1
    sync!
    id
  end

  def self.close!(id : Int64) : Nil
    return unless @@sessions.has_key?(id)
    @@sessions[id].close
    drop(id)
  end

  def self.pick!(index : Int32) : Nil
    @@selected = index.clamp(0, {@@order.size - 1, 0}.max)
    sync!
  end

  # Paste: clipboard-порт + bracketed-paste-обёртка эмулятора — «как
  # достать» живёт здесь, не в меню.
  def self.paste!(id : Int64) : Nil
    return unless (s = @@sessions[id]?) && (text = Egui::SystemPorts::Clipboard.text)
    s.write(s.term.paste_bytes(text))
  end

  # Copy: выделение (жесты — забота TermView) → clipboard-порт.
  def self.copy!(id : Int64) : Nil
    return unless (s = @@sessions[id]?)
    if (sel = s.term.selection_text)
      Egui::SystemPorts::Clipboard.text = sel
    end
  end

  # Репа мёртвых детей: смерть = переход состояния, читатель наблюдает
  # (§4.1); последняя вкладка уносит приложение — сторож на бэкенде.
  def self.reap! : Nil
    dead = @@order.select { |id| !@@sessions[id].alive? }
    return if dead.empty?
    dead.each { |id| drop(id) }
  end

  def self.drop(id : Int64) : Nil
    idx = @@order.index(id)
    return unless idx
    @@order.delete_at(idx)
    @@sessions.delete(id)
    @@selected -= 1 if idx < @@selected
    @@selected = @@selected.clamp(0, {@@order.size - 1, 0}.max) unless @@order.empty?
    sync!
    Egui::SystemPorts::Quit.quit! if @@order.empty?
  end

  # --- профили ------------------------------------------------------------

  def self.pick_profile!(name : String) : Nil
    config.active = name if config.profiles.has_key?(name)
    sync_profiles!
  end

  def self.update_profile!(fields : JSON::Any) : Nil
    p = config.active_profile
    if (raw = fields["opacity"]?) && (v = raw.as_f?)
      p.opacity = v.clamp(0.3, 1.0)
    end
    if (raw = fields["bg"]?) && (rgb = raw.as_a?)
      r, g, b = rgb
      p.background_color = Egui::Color32.rgb(r.as_i, g.as_i, b.as_i)
    end
    if (raw = fields["blink"]?) && (blink = raw.as_bool?)
      p.cursor_blinks = blink
    end
    sync_profiles!
  end

  def self.add_profile!(name : String) : Nil
    return if name.empty? || config.profiles.has_key?(name)
    config.profiles[name] = config.active_profile.dup
    config.active = name
    sync_profiles!
  end

  def self.delete_profile! : Nil
    return unless config.profiles.size > 1
    config.profiles.delete(config.active)
    config.active = config.profiles.keys.first
    sync_profiles!
  end

  def self.save_config! : Nil
    config.save
  end
end

# --- Контроллеры ------------------------------------------------------------

class SessionsController < Egui::Mvc::Controller
  def index(request)
    {"tabs" => TerminalRepo.sessions.keys, "selected" => 0}
  end

  # POST /sessions — новая вкладка (нативная PTY через фабрику).
  def create(request)
    TerminalRepo.open!(request.body["cwd"]?.try(&.as_s?))
    {"opened" => true}
  end

  # POST /sessions/pick — выбор вкладки.
  def choose(request)
    TerminalRepo.pick!(request.body["index"]?.try(&.as_i) || 0)
    {"ok" => true}
  end

  # DELETE /sessions/:id — закрыть вкладку, отпустить PTY.
  def destroy(request)
    TerminalRepo.close!(request.params["id"].to_i64)
    {"closed" => true}
  end

  # POST /sessions/:id/copy|paste — clipboard-мост.
  def copy(request)
    TerminalRepo.copy!(request.params["id"].to_i64)
    {"ok" => true}
  end

  def paste(request)
    TerminalRepo.paste!(request.params["id"].to_i64)
    {"ok" => true}
  end

  actions
end

class ProfilesController < Egui::Mvc::Controller
  # PUT /profiles — правка полей активного профиля (слайдеры шлют
  # дебаунсом с фронта).
  def update(request)
    TerminalRepo.update_profile!(request.body)
    {"ok" => true}
  end

  # POST /profiles/pick — выбрать активный.
  def pick(request)
    TerminalRepo.pick_profile!(request.body["name"]?.try(&.as_s) || "")
    {"ok" => true}
  end

  # POST /profiles — новый профиль-копия активного.
  def create(request)
    TerminalRepo.add_profile!(request.body["name"]?.try(&.as_s) || "")
    {"ok" => true}
  end

  # DELETE /profiles — удалить активный (не последний).
  def destroy(request)
    TerminalRepo.delete_profile!
    {"ok" => true}
  end

  # POST /profiles/save — явное сохранение в JSON (AppConfig-порт).
  def save(request)
    TerminalRepo.save_config!
    {"saved" => true}
  end

  actions
end

TERMINAL_ROUTES = Egui::Mvc::Router.new.draw do |r|
  r.post "/sessions", SessionsController, "create"
  r.post "/sessions/pick", SessionsController, "choose"
  r.post "/sessions/:id/copy", SessionsController, "copy"
  r.post "/sessions/:id/paste", SessionsController, "paste"
  r.delete "/sessions/:id", SessionsController, "destroy"
  r.get "/sessions", SessionsController, "index"
  r.put "/profiles", ProfilesController, "update"
  r.post "/profiles", ProfilesController, "create"
  r.post "/profiles/pick", ProfilesController, "pick"
  r.post "/profiles/save", ProfilesController, "save"
  r.delete "/profiles", ProfilesController, "destroy"
end
