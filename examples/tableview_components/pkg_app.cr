require "./backend"

# ═══ FRONTEND ═════════════════════════════════════════════════════════
# Вид: таблица + тулбар, ноль бизнес-правил — только request. ListStore
# — одноразовый кэш ответа index (plans/frontend-backend-split.md §7:
# фронтендный стейт можно выкинуть и восстановить из стора).

class PkgApp < Egui::App
  # Model columns: status / name / installed ver / available ver /
  # size (KiB) / section.
  STATUS = 0
  NAME = 1
  INSTALLED = 2
  AVAILABLE = 3
  SIZE = 4
  SECTION = 5

  getter store = Egui::ListStore.new(:string, :string, :string, :string,
    :int, :string)

  @view : Egui::TableView
  @search = ""
  @message = "Welcome — click headers to sort, drag their edges to resize"

  def initialize
    super
    # Разводка (до фазы 5 — руками; Egui.run займётся ею с App API).
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(PKG_ROUTES)
    @view = Egui::TableView.new("packages", store)
    @view.selection.mode = :multiple
    @view.empty_text = "no packages match"
    @view.column("Status", STATUS, fraction: 0.13, min_width: 70.0)
    @view.column("Package", NAME, fraction: 0.27)
    @view.column("Installed", INSTALLED, fraction: 0.11)
    @view.column("Available", AVAILABLE, fraction: 0.11)
    @view.column("Size", SIZE, fraction: 0.10, align: :right)
      .format = ->PkgApp.human_size(Egui::ListStore::Value)
    @view.column("Section", SECTION, fraction: 0.16)
    # Status colors: the Synaptic package states.
    @view.column("Status", STATUS).color = ->status_color(Int32)
    @view.on_activate { |row| activate(row) }
    refresh
  end

  def self.human_size(v : Egui::ListStore::Value) : String
    kb = v.as(Int32)
    return "#{kb} KiB" if kb < 1024
    "#{"%.1f" % (kb / 1024.0)} MiB"
  end

  def status_color(row : Int32) : Egui::Color32
    v = Egui::Color32.rgb(0x9e, 0x9e, 0x9e) # not installed — dim
    case store.get_string(row, STATUS)
    when "installed"  then v = Egui::Color32.rgb(0x4e, 0xc9, 0x4e)
    when "upgradable" then v = Egui::Color32.rgb(0xe0, 0xa2, 0x3a)
    when "broken"     then v = Egui::Color32.rgb(0xe0, 0x5d, 0x5d)
    end
    v
  end

  # --- транспорт ---------------------------------------------------------

  # Перечитать таблицу под текущий поиск. Ответ приезжает между кадрами;
  # устаревшие ответы (юзер уже допечатал) молча выбрасываются —
  # latest-wins на стороне фронта.
  def refresh : Nil
    Egui.request "GET", "/packages?search=#{URI.encode_www_form(@search)}" do |resp|
      if resp.ok? && resp.body["search"].as_s == @search.strip.downcase
        store.clear
        resp.body["rows"].as_a.each do |r|
          store.append(r[0].as_s, r[1].as_s, r[2].as_s, r[3].as_s,
            r[4].as_i, r[5].as_s)
        end
      end
    end
  end

  # Двойной клик: намерение ушло, бизнес-правило — на той стороне.
  def activate(row : Int32) : Nil
    name = store.get_string(row, NAME)
    Egui.request "PATCH", "/packages/#{name}", action: "toggle" do |resp|
      @message = resp.body["message"]?.try(&.as_s) ||
                 resp.body["error"]?.try(&.as_s).to_s
      refresh
    end
  end

  def act_on_selection(action : String) : Nil
    names = @view.selection.rows.to_a.sort!.map { |r| store.get_string(r, NAME) }
    @view.selection.clear
    Egui.request "POST", "/packages/bulk",
        action: action, names: names do |resp|
      @message = resp.body["message"]?.try(&.as_s) ||
                 resp.body["error"]?.try(&.as_s).to_s
      refresh
    end
  end

  # --- вид ----------------------------------------------------------------

  def update(ctx : Egui::Context) : Nil
    ctx.top_panel("toolbar", height: 44.0, resizable: false) do |ui|
      ui.label("Search")
      ui.text_edit_singleline(@search, hint: "package name…",
        focus_id: "search") do |text|
        @search = text
        refresh
      end
      if ui.button("Mark install").clicked?
        act_on_selection("install")
      end
      if ui.button("Mark remove").clicked?
        act_on_selection("remove")
      end
      if ui.button("Upgrade").clicked?
        act_on_selection("install")
      end
      if ui.button("Clear").clicked? && !@view.selection.rows.empty?
        @view.selection.clear
        @message = "Selection cleared"
      end
    end

    ctx.central_panel do |ui|
      @view.show(ui)
    end

    ctx.bottom_panel("status", height: 28.0, resizable: false) do |ui|
      ui.label("#{store.display_count} packages, " \
               "#{@view.selection.count} selected — #{@message}")
    end
  end
end
