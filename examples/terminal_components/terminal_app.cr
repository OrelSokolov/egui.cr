require "json"
require "./backend"

# ═══ FRONTEND (terminal) ══════════════════════════════════════════════
# Вид на сторе: список табов/selected/профили — подписки на StateView
# (подписка = repaint, данные едят в кадре из кэша). TermView держит
# порт-сессию по ссылке и кормит вводом сам (скроллбэк — состояние
# сессии, НЕ стрим §4.1); контрольная плоскость (open/close/copy/
# paste, профили) — только request. Скрытые вкладки качаются здесь же
# (механика смежная с рендером: их вывод не ждёт показа).

class TerminalApp < Egui::App
  MIN_OPACITY = 0.3

  # Кэш слайсов стора (подписки обновляют, кадр читает).
  getter tab_ids = [] of Int64
  getter profile_active = "default"
  @selected = 0
  @profile_names = ["default"]
  @profile_active = "default"
  @profile_opacity = 1.0
  @profile_bg = {220, 220, 220}
  @profile_blink = false

  # App actions (menus and hotkeys reference these, never key strings).
  ACTION_NEW_TAB   = Egui::HotkeyAction.new("terminal.new_tab")
  ACTION_CLOSE_TAB = Egui::HotkeyAction.new("terminal.close_tab")
  DEFAULT_BINDINGS = {
    ACTION_NEW_TAB   => "Ctrl+T",
    ACTION_CLOSE_TAB => "Ctrl+W",
  }
  @hotkeys_ready = false

  getter theme : Egui::Terminal::Theme
  property? settings_open : Bool = false
  @new_profile_name : String = ""
  @dirty : Bool = false
  # Дебаунс правок профиля (слайдер тянется кадрами — едет ОДИН запрос).
  @profile_commit_due : Float64? = nil
  @focused_id : Int64? = nil
  @term_menu : Egui::ContextMenu?

  def initialize
    super()
    TerminalRepo.boot!
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(TERMINAL_ROUTES)
    @theme = Egui::Terminal::Theme.new
    # Стартовая вкладка — намерением, как вся контрольная плоскость.
    Egui.request "POST", "/sessions" { |_r| }
    # Подписки стора → локальный кэш (фронт НИКОГДА не пишет в стор).
    Egui::Mvc.state.subscribe("terminal/tabs") do |v|
      @tab_ids = v.as_a.map(&.as_i64)
      ctx.request_repaint
    end
    Egui::Mvc.state.subscribe("terminal/selected") do |v|
      @selected = v.as_i
      ctx.request_repaint
    end
    Egui::Mvc.state.subscribe("terminal/profiles") do |v|
      @profile_names = v["names"].as_a.map(&.as_s)
      @profile_active = v["active"].as_s
      @profile_opacity = v["opacity"].as_f
      rgb = v["bg"].as_a
      @profile_bg = {rgb[0].as_i, rgb[1].as_i, rgb[2].as_i}
      @profile_blink = v["blink"].as_bool
      ctx.request_repaint
    end
  end

  def active_id : Int64?
    @tab_ids[@selected]?
  end

  # Титулы — живое чтение эмулятора (OSC-тайтлы печатаются потоком);
  # вычислять их на бэкенде значило бы сериализовать состояние сессии.
  def tab_title(id : Int64, active : Bool) : String
    title = (TerminalRepo.session(id).try &.term.title) || ""
    title = "sh" if title.empty?
    active ? "▸ #{title}" : title
  end

  def update(ctx : Egui::Context) : Nil
    apply_appearance(ctx)
    TerminalRepo.reap!

    # Скрытые сессии не рендерятся, но их PTY производят: качаем их
    # здесь (дёшево per-session, стоимость кадра плоская по вкладкам).
    @tab_ids.each_with_index do |id, i|
      TerminalRepo.session(id).try &.pump if i != @selected
    end

    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    ctx.menu_bar do |bar|
      bar.menu_button("File") do |menu|
        menu.menu_item("New Tab", ACTION_NEW_TAB)
        menu.menu_item("Close Tab", ACTION_CLOSE_TAB)
      end
      bar.menu_button("Edit") do |menu|
        menu.menu_item("Copy", icon: :copy, hotkey: "Ctrl+Shift+C") do
          copy_selection
        end
        menu.menu_item("Paste", icon: :paste, hotkey: "Ctrl+Shift+V") do
          paste_clipboard
        end
      end
      bar.menu_button("Settings") do |menu|
        menu.menu_item(settings_open? ? "Hide Settings" : "Settings…") do
          self.settings_open = !settings_open?
        end
      end
    end

    if settings_open?
      ctx.side_panel(:right, "settings", width: 300.0) do |ui|
        ui.heading("Settings")
        ui.combo_box("profile", @profile_active, @profile_names) do |name|
          send_req("POST", "/profiles/pick", name: name)
        end
        ui.horizontal do |row|
          row.text_edit_singleline(@new_profile_name,
            hint: "new profile name") { |t| @new_profile_name = t }
          if row.button("Add").clicked? &&
             !(name = @new_profile_name.strip).empty?
            send_req("POST", "/profiles", name: name)
            @new_profile_name = ""
            @dirty = true
          end
          if row.button("Delete").clicked? && @profile_names.size > 1
            send_req("DELETE", "/profiles")
            @dirty = true
          end
        end
        ui.separator

        # Правки — эфемерное виджетное состояние, коммит дебаунсом.
        ui.label("Terminal background opacity:")
        ui.slider(@profile_opacity, MIN_OPACITY..1.0) do |v|
          @profile_opacity = v
          @dirty = true
          @profile_commit_due = ctx.input.time + 0.2
        end
        ui.separator
        ui.label("Background color:")
        r, g, b = @profile_bg
        ui.color_edit32(Egui::Color32.rgb(r, g, b)) do |c|
          @profile_bg = {c.r.to_i, c.g.to_i, c.b.to_i}
          @dirty = true
          @profile_commit_due = ctx.input.time + 0.2
        end
        ui.separator
        ui.checkbox(@profile_blink, "Blinking cursor") do |v|
          @profile_blink = v
          @dirty = true
          @profile_commit_due = ctx.input.time + 0.2
        end

        ui.separator
        if ui.button(@dirty ? "Save •" : "Save").clicked?
          @dirty = false
          send_req("POST", "/profiles/save")
        end
      end
    end

    flush_profile_commit(ctx)

    ctx.central_panel do |ui|
      unless @tab_ids.empty?
        titles = @tab_ids.each_with_index.map { |id, i|
          tab_title(id, i == @selected)
        }.to_a
        ui.tabs(titles, @selected, closable: true,
          on_close: ->(t : Int32) { close_tab(t) }) do |t|
          send_req("POST", "/sessions/pick", index: t)
          @selected = t # оптимистично; конверт подтвердит
        end

        if (id = active_id) && (session = TerminalRepo.session(id))
          resp = ui.terminal(session, theme: theme,
            cursor_blinks: @profile_blink)
          unless id == @focused_id
            @focused_id = id
            ctx.memory.focus.request(resp.id)
          end
          resp.context_menu(term_menu)
        end
      end
    end

    ctx.bottom_panel("status") do |ui|
      if (id = active_id) && (s = TerminalRepo.session(id))
        if (code = s.exit_code)
          ui.label("exited: #{code}")
        else
          ui.label("FPS: #{"%.1f" % ctx.fps} — " \
                   "#{s.term.cols}×#{s.term.rows}" \
                   " — scrollback #{s.term.display_offset}" \
                   " — #{@profile_active}")
        end
      end
    end

    if ctx.consume_action(ACTION_NEW_TAB)
      send_req("POST", "/sessions")
    end
    close_tab(@selected) if ctx.consume_action(ACTION_CLOSE_TAB) && !@tab_ids.empty?
  end

  private def send_req(method : String, path : String, **body) : Nil
    Egui.request(method, path, **body) { |_r| }
  end

  private def flush_profile_commit(ctx : Egui::Context) : Nil
    if (due = @profile_commit_due) && ctx.input.time >= due
      @profile_commit_due = nil
      r, g, b = @profile_bg
      send_req("PUT", "/profiles",
        opacity: @profile_opacity, bg: [r, g, b], blink: @profile_blink)
    end
  end

  private def close_tab(t : Int32) : Nil
    return unless (id = @tab_ids[t]?)
    send_req("DELETE", "/sessions/#{id}")
  end

  private def copy_selection : Nil
    if (id = active_id)
      send_req("POST", "/sessions/#{id}/copy")
    end
  end

  private def paste_clipboard : Nil
    if (id = active_id)
      send_req("POST", "/sessions/#{id}/paste")
    end
  end

  private def term_menu : Egui::ContextMenu
    @term_menu ||= Egui::ContextMenu.new
      .item("Copy", icon: :copy, hotkey: "Ctrl+Shift+C") { copy_selection }
      .item("Paste", icon: :paste, hotkey: "Ctrl+Shift+V") { paste_clipboard }
  end

  # Активный профиль → терминальная тема: альфа фона — только у сетки.
  private def apply_appearance(ctx : Egui::Context) : Nil
    alpha = (@profile_opacity.clamp(MIN_OPACITY, 1.0) * 255.0).round.to_u8
    r, g, b = @profile_bg
    theme.background = Egui::Color32.new(r.to_u8, g.to_u8, b.to_u8, alpha)
  end
end
