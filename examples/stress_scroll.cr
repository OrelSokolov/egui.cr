# Stress-scroll demo — the widgets_bench cases as a LIVE app: pick a
# case and a row count (up to 5000), scroll it with the wheel, the
# HUD (top-right) shows live fps / frame build ms / paint-cache hits.
# The frame itself is the optimization story: static content replays
# from the paint cache, off-screen flex rows cull — thousands of
# widgets scroll like ~30.
#
#   crystal run --release examples/stress_scroll.cr
#   PERFORMANCE_OVERLAY=1 …  # + виджет-спаны поверх (PerfOverlay)

require "../src/egui/driver_selector"

GC.disable if ENV["NO_GC"]?

class StressScrollApp < Egui::App
  alias Render = Proc(Egui::Ui, Int32, Nil)
  record Kase, name : String, desc : String, render : Render

  GRAD = Egui::Gradient.parse?(
    "linear-gradient(135deg, #E92236 0%, #571DCC 60%, #26C6DA 100%)"
  ) || Egui::Gradient.new(:linear, [] of Egui::Gradient::Stop, 135.0)

  SVG_ICON = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>)

  CASES = [
    Kase.new("label", "обычные строки", ->(ui : Egui::Ui, i : Int32) {
      ui.label("Строка ##{i} — обычный текст") }),
    Kase.new("h1", "крупный текст", ->(ui : Egui::Ui, i : Int32) {
      ui.heading("Заголовок ##{i}") }),
    Kase.new("rich", "цвет/размер", ->(ui : Egui::Ui, i : Int32) {
      ui.rich(Egui::RichText.new("Цветной ##{i}")
        .size(11.0 + (i % 3) * 4.0)
        .color(Egui::Color32.rgb((i * 7) % 255, 120, 220))) }),
    Kase.new("div", "плоская заливка", ->(ui : Egui::Ui, i : Int32) {
      ui.box(fill: Egui::Color32.rgba(40, 44, 52, 255), height: 26) { |b|
        b.label("Div ##{i}", userselect: false) }
      # explicit nil: `box` returns Rect — a struct implicitly returned
      # through the Proc(..., Nil) alias leaks x87 return slots at every
      # .call (the phantom-NaN crash; see src/egui/math.cr Rect NOTE).
      nil }),
    Kase.new("градиент", "linear-gradient", ->(ui : Egui::Ui, i : Int32) {
      ui.box(fill: GRAD, height: 26) { |b|
        b.label("Градиент ##{i}", userselect: false) }
      nil }),
    Kase.new("кнопка в высоту", "кнопки колонкой", ->(ui : Egui::Ui, i : Int32) {
      ui.button("Кнопка ##{i}") }),
    Kase.new("кнопка в ряд", "horizontal wrap", ->(ui : Egui::Ui, i : Int32) {
      ui.horizontal(wrap: true) { |h| h.button("##{i}") } }),
    Kase.new("flex-строка", "3 ребёнка: label+кнопка+chip", ->(ui : Egui::Ui, i : Int32) {
      ui.flex(gap: 8.0, align: :center) do |f|
        f.child(grow: 1.0, basis: 0.0) { |c| c.label("Строка ##{i}") }
        f.child { |c| c.button("Открыть") }
        f.child { |c| c.label("·") }
      end
      nil }),  # flex returns Rect — same x87 leak as `div` above
    Kase.new("карточка", "fill+stroke+скругление+flex", ->(ui : Egui::Ui, i : Int32) {
      ui.box(fill: Egui::Color32.rgba(32, 36, 44, 255),
             stroke: Egui::Color32.rgba(70, 76, 88, 255),
             rounding: 8.0) do |b|
        b.flex(gap: 8.0, align: :center) do |f|
          f.child(grow: 1.0, basis: 0.0) { |c| c.label("Карточка ##{i}") }
          f.child { |c| c.button("⋯") }
        end
      end
      nil }),  # box returns Rect — see the `div` case note
    Kase.new("checkbox", "чекбоксы", ->(ui : Egui::Ui, i : Int32) {
      ui.checkbox(i.even?, "Опция ##{i}") }),
    Kase.new("radio", "радиокнопки", ->(ui : Egui::Ui, i : Int32) {
      ui.radio(i.zero?, "Вариант ##{i}") }),
    Kase.new("toggle", "toggle-switch", ->(ui : Egui::Ui, i : Int32) {
      ui.toggle_button(i.even?, "Switch ##{i}") }),
    Kase.new("slider", "слайдеры", ->(ui : Egui::Ui, i : Int32) {
      ui.slider((i % 100).to_f64, 0.0..100.0, "Ползунок ##{i}") { |_v| } }),
    Kase.new("progress", "прогресс-бары", ->(ui : Egui::Ui, i : Int32) {
      ui.progress_bar((i % 100).to_f64 / 100.0) }),
    Kase.new("separator", "разделители", ->(ui : Egui::Ui, _i : Int32) {
      ui.separator }),
    Kase.new("text_edit", "поля ввода", ->(ui : Egui::Ui, i : Int32) {
      ui.text_edit_singleline("поле ##{i}") { |_v| } }),
    Kase.new("combo", "комбобоксы", ->(ui : Egui::Ui, i : Int32) {
      ui.combo_box("stress-combo-#{i}", "Вариант #{i % 3}",
        ["Вариант 0", "Вариант 1", "Вариант 2", "Вариант 3"]) { |_v| } }),
    Kase.new("svg-иконка", "вектор 16×16", ->(ui : Egui::Ui, _i : Int32) {
      ui.svg(SVG_ICON, size: Egui::Vec2.new(16.0, 16.0)) }),
    Kase.new("nested box", "box в box в box", ->(ui : Egui::Ui, i : Int32) {
      ui.box(fill: Egui::Color32.rgba(40, 44, 52, 255)) do |outer|
        outer.box(stroke: Egui::Color32.rgba(80, 86, 98, 255)) do |inner|
          inner.label("Вложенный ##{i}", userselect: false)
        end
      end
      nil }),  # box returns Rect — see the `div` case note
    Kase.new("вложенный скролл (label)", "scrolledlabel", ->(ui : Egui::Ui, i : Int32) {
      ui.scrolledlabel("Строка ##{i} — длинный текст во вложенном скролле " * 6,
        max_height: 48.0) }),
    Kase.new("вложенный скролл (area)", "scroll_area в scroll_area", ->(ui : Egui::Ui, i : Int32) {
      ui.scroll_area(max_height: 60.0) do |inner|
        5.times { |r| inner.label("Область ##{i}, строка #{r + 1}") }
      end
      nil }),  # scroll_area returns Rect — see the `div` case note
  ]

  def initialize
    super
    # Debug/driver hook: pick the case from the environment (headless
    # repros — tmp/nan_repro2.py — can't click sidebar radios reliably).
    @sel = ENV["STRESS_CASE"]?.try(&.to_i?) || 0
    @count = 1000
    @continuous = true
    # HUD window
    @t0 = 0.0_f64
    @frames = 0
    @fps = 0.0_f64
    @build_ms = 0.0_f64
    @hit0 = 0
    @miss0 = 0
    @hits_per_frame = 0.0_f64
    @hit_pct = 100.0_f64
  end

  def update(ctx : Egui::Context) : Nil
    # Debug probe for the phantom-NaN hunt (see tmp/nan_repro2.py): the
    # exact from_min_size call at frame-build time, outside any
    # box/scroll context.
    if ENV["NAN_PROBE"]?
      100.times do |k|
        r = Egui::Rect.from_min_size(
          Egui::Pos2.new(250.0, 317.0 + k * 0.1),
          Egui::Vec2.new(514.0, 1_000_000.0))
        raise "NAN_PROBE: #{r.max.inspect}" unless r.max.y.finite?
      end
    end
    tick_hud(ctx)
    ctx.request_repaint if @continuous

    ctx.side_panel(:left, "stress_cases", width: 230.0, resizable: false) do |side|
      side.heading("stress scroll")
      side.label("кейс и количество — потом крути колесо", wrap: true,
        userselect: false)
      side.separator
      CASES.each_with_index do |k, idx|
        if side.radio(idx == @sel, "#{k.name} — #{k.desc}").clicked?
          @sel = idx
        end
      end
      side.separator
      side.label("строк:", userselect: false)
      {100, 1000, 5000}.each do |n|
        if side.radio(@count == n, n.to_s).clicked?
          @count = n
        end
      end
      side.separator
      side.checkbox(@continuous, "непрерывный рендер") { |v| @continuous = v }
    end

    ctx.central_panel do |ui|
      kase = CASES[@sel]
      ui.heading("#{@count} × #{kase.name}")
      ui.label("#{kase.desc} · статичный контент, paint-cache + off-screen cull",
        wrap: true, userselect: false)
      ui.separator
      t0 = Time.instant
      ui.scroll_area do |scroll|
        @count.times { |i| kase.render.call(scroll, i) }
      end
      @build_ms = (Time.instant - t0).total_milliseconds
    end

    paint_hud(ctx)
  end

  private def tick_hud(ctx : Egui::Context) : Nil
    t = ctx.input.time
    @t0 = t if @t0 <= 0.0
    @frames += 1
    return unless t - @t0 >= 0.5
    dt = t - @t0
    @fps = @frames / dt
    cache = ctx.paint_cache
    @hits_per_frame = (cache.hits - @hit0) / @frames.to_f64
    total = (cache.hits - @hit0) + (cache.misses - @miss0)
    @hit_pct = total.zero? ? 100.0 : (cache.hits - @hit0) * 100.0 / total
    @hit0 = cache.hits
    @miss0 = cache.misses
    @frames = 0
    @t0 = t
  end

  private def paint_hud(ctx : Egui::Context) : Nil
    screen = ctx.input.screen_rect
    painter = ctx.painter
    painter.layer = Egui::POPUP_LAYER_Z - 1
    painter.clip = screen

    lines = {
      "fps        %.0f" % @fps,
      "build      %.2f ms" % @build_ms,
      "cache hit  %.0f%% (%.0f/кадр)" % {@hit_pct, @hits_per_frame},
    }
    w = 210.0
    h = 8.0 + lines.size * 17.0 + 8.0
    x0 = screen.max.x - 8.0 - w
    painter.rect(Egui::Rect.from_min_size(Egui::Pos2.new(x0, 8.0),
      Egui::Vec2.new(w, h)), 6.0,
      Egui::Color32.rgba(16, 16, 24, 228), Egui::Color32.rgba(90, 90, 110, 255), 1.0)
    green = Egui::Color32.rgba(120, 220, 160, 255)
    lines.each_with_index do |text, i|
      painter.text(Egui::Pos2.new(x0 + 10.0, 16.0 + i * 17.0 + 8.0),
        text, 13.0, green)
    end
  end
end

Egui.run(StressScrollApp.new,
  title: "stress scroll — 1000× виджеты, paint-cache + cull")
