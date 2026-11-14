# Headless WIDGET stress bench: N static copies of ONE widget kind on
# a scrollable page, generated ON THE FLY each frame (a prebuilt
# static page would ride the paint cache and measure nothing). The
# same harness shape as bench/html_bench.cr: Egui::Bench drives
# update()/end_frame, no sokol backend.
#
# Each DSL case is "взять пример × умножить на N" — 1000 h1, 1000
# div, 1000 градиентных заливок, 1000 кнопок в ряд / в высоту, … —
# benchmarking the WIDGETS and the LAYOUTS themselves. The content
# never changes across frames (the paint-cache sweet spot); the scroll
# scenario turns the wheel every frame, the "листаю 1000 статичных
# элементов" user action.
#
#   crystal build --release bench/widgets_bench.cr -o bin/benchmarks/widgets && ./bin/benchmarks/widgets
#   N=5000 ./bin/benchmarks/widgets          # больше элементов на страницу
#   ONLY=кноп ./bin/benchmarks/widgets       # только case'ы, содержащие подстроку
#   IDLE=0 ./bin/benchmarks/widgets          # только скролл-проход
#
# Output: по мере прогона — прогресс `[x из y] case — desc`, в конце —
# REPORT, отсортированный по убыванию нагрузки (ms/frame при скролле).

require "../src/egui"
require "../src/egui/driver/crystalfonts"

N      = (ENV["N"]? || "1000").to_i
WIDTH  = (ENV["BENCH_W"]? || "1100").to_f64
HEIGHT = (ENV["BENCH_H"]? || "800").to_f64
WARMUP = (ENV["WARMUP"]? || "5").to_i
FRAMES = (ENV["FRAMES"]? || "30").to_i
SCROLL_ONLY = ENV["IDLE"]? == "0"

# Real font stack, like Sokol#on_init picks one — forced to the pure
# Crystal backend (what release ships): the headless monospace
# estimate would make measure() free and the bench would measure a
# different program than the one shipping.
def bench_font : Egui::Driver::CrystalFonts?
  paths = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
  ].select { |p| File.exists?(p) }
  return nil if paths.empty?
  Egui::Driver::CrystalFonts.from_system(paths)
end

module WidgetsBench
  # One DSL entry: a page of `count` copies of one widget kind, built
  # by `render` (receives the scroll-area Ui and the item index — the
  # same index every frame, so the content is fully static).
  class Case
    getter name : String
    getter desc : String
    getter count : Int32
    getter render : Proc(Egui::Ui, Int32, Nil)

    def initialize(@name, @desc, @count, &block : Egui::Ui, Int32 -> Nil)
      @render = block
    end
  end

  CASES = [] of Case

  def self.page(name : String, desc : String = "",
                &render : Egui::Ui, Int32 -> Nil) : Nil
    CASES << Case.new(name, desc, N) { |ui, i| render.call(ui, i) }
  end

  # The page app: the case's items inside one vertical scroll area.
  # A fresh instance per scenario (scroll state and caches start cold).
  class PageApp < Egui::App
    def initialize(@kase : Case)
      super()
    end

    def update(ctx : Egui::Context) : Nil
      ctx.central_panel do |ui|
        ui.scroll_area do |scroll|
          @kase.count.times { |i| @kase.render.call(scroll, i) }
        end
      end
    end
  end

  # -- the runner -----------------------------------------------------------

  # One case's measured numbers (p50 over the measured frames).
  class Result
    getter kase : Case
    property scroll_ms : Float64 = 0.0 # p50 ms/frame при скролле
    property idle_ms : Float64 = 0.0   # p50 ms/frame без скролла
    property cache_hit : Float64 = 0.0 # paintcache hit rate, %

    def initialize(@kase : Case)
    end

    # Первичная метрика — нагрузка при скролле (главный сценарий
    # «спокойно листаю 1000 статичных элементов»); idle — справочная.
    def load_ms : Float64
      scroll_ms
    end
  end

  def self.p50_ms(report : Egui::Bench::Report) : Float64
    return 0.0 if report.frame_stats.empty?
    totals = report.frame_stats.map(&.total_ns).sort
    totals[totals.size // 2].to_f64 / 1_000_000.0
  end

  def self.cache_hit(report : Egui::Bench::Report) : Float64
    hit = report.counters["paintcache.hit"]? || 0
    miss = report.counters["paintcache.miss"]? || 0
    return 0.0 if hit + miss == 0
    hit * 100.0 / (hit + miss)
  end

  def self.run_case(kase : Case) : Result
    result = Result.new(kase)
    font = bench_font
    verbose = ENV["VERBOSE"]? == "1"

    # Scroll pass: pointer в центре страницы + 4 wheel-нотча вниз за
    # кадр — реально листаем список, offset меняется каждый кадр
    # (hit-testing'у колеса нужна позиция курсора, поэтому и
    # pointer_moved). Положительный delta.y листает ВНИЗ по списку.
    app = PageApp.new(kase)
    app.ctx.fonts = font if font
    report = Egui::Bench.run(app, width: WIDTH, height: HEIGHT,
      warmup: WARMUP, frames: FRAMES, mouse: false, print: verbose) do |d|
      d.mouse_move(WIDTH / 2.0, HEIGHT / 2.0)
      4.times { d.scroll(0.0, 3.0) }
    end
    result.scroll_ms = p50_ms(report)
    result.cache_hit = cache_hit(report)

    unless SCROLL_ONLY
      # Idle pass: ничего не меняется, курсор стоит — чистый кэш-кадр.
      app = PageApp.new(kase)
      app.ctx.fonts = font if font
      report = Egui::Bench.run(app, width: WIDTH, height: HEIGHT,
        warmup: WARMUP, frames: FRAMES, mouse: true, print: false)
      result.idle_ms = p50_ms(report)
    end

    result
  end
end

# -- DSL: cases ---------------------------------------------------------------

GRAD = Egui::Gradient.parse?(
  "linear-gradient(135deg, #E92236 0%, #571DCC 60%, #26C6DA 100%)"
) || Egui::Gradient.new(:linear, [] of Egui::Gradient::Stop, 135.0)

SVG_ICON = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>)

WidgetsBench.page "1000 × label", "обычные строки" do |ui, i|
  ui.label("Строка ##{i} — обычный текст")
end

WidgetsBench.page "1000 × h1", "heading — крупный текст" do |ui, i|
  ui.heading("Заголовок ##{i}")
end

WidgetsBench.page "1000 × rich", "цвет/размер через RichText" do |ui, i|
  ui.rich(Egui::RichText.new("Цветной ##{i}")
    .size(11.0 + (i % 3) * 4.0)
    .color(Egui::Color32.rgb((i * 7) % 255, 120, 220)))
end

WidgetsBench.page "1000 × div", "box с плоской заливкой" do |ui, i|
  ui.box(fill: Egui::Color32.rgba(40, 44, 52, 255), height: 26) { |b|
    b.label("Div ##{i}", userselect: false)
  }
end

WidgetsBench.page "1000 × градиент", "box с linear-gradient заливкой" do |ui, i|
  ui.box(fill: GRAD, height: 26) { |b|
    b.label("Градиент ##{i}", userselect: false)
  }
end

WidgetsBench.page "1000 × кнопка (в высоту)", "кнопки в колонку" do |ui, i|
  ui.button("Кнопка ##{i}")
end

WidgetsBench.page "1000 × кнопка (в ряд)", "horizontal wrap — переносятся по ширине" do |ui, i|
  ui.horizontal(wrap: true) { |h| h.button("##{i}") }
end

WidgetsBench.page "1000 × flex-строка", "flex на 3 ребёнка (label+кнопка+chip)" do |ui, i|
  ui.flex(gap: 8.0, align: :center) do |f|
    f.child(grow: 1.0, basis: 0.0) { |c| c.label("Строка ##{i}") }
    f.child { |c| c.button("Открыть") }
    f.child { |c| c.label("·") }
  end
end

WidgetsBench.page "1000 × карточка", "box(fill+stroke+скругление) с label+кнопкой" do |ui, i|
  ui.box(fill: Egui::Color32.rgba(32, 36, 44, 255),
         stroke: Egui::Color32.rgba(70, 76, 88, 255), rounding: 8.0) do |b|
    b.flex(gap: 8.0, align: :center) do |f|
      f.child(grow: 1.0, basis: 0.0) { |c| c.label("Карточка ##{i}") }
      f.child { |c| c.button("⋯") }
    end
  end
end

WidgetsBench.page "1000 × checkbox", "чекбоксы" do |ui, i|
  ui.checkbox(i.even?, "Опция ##{i}")
end

WidgetsBench.page "1000 × radio", "радиокнопки" do |ui, i|
  ui.radio(i.zero?, "Вариант ##{i}")
end

WidgetsBench.page "1000 × toggle", "toggle-switch кнопки" do |ui, i|
  ui.toggle_button(i.even?, "Switch ##{i}")
end

WidgetsBench.page "1000 × slider", "горизонтальные слайдеры" do |ui, i|
  ui.slider((i % 100).to_f64, 0.0..100.0, "Ползунок ##{i}") { |_v| }
end

WidgetsBench.page "1000 × progress", "прогресс-бары" do |ui, i|
  ui.progress_bar((i % 100).to_f64 / 100.0)
end

WidgetsBench.page "1000 × separator", "разделители" do |ui, _i|
  ui.separator
end

WidgetsBench.page "1000 × text_edit", "однострочные поля ввода" do |ui, i|
  ui.text_edit_singleline("поле ##{i}") { |_v| }
end

WidgetsBench.page "1000 × combo", "комбобоксы" do |ui, i|
  ui.combo_box("bench-combo-#{i}", "Вариант #{i % 3}",
    ["Вариант 0", "Вариант 1", "Вариант 2", "Вариант 3"]) { |_v| }
end

WidgetsBench.page "1000 × svg-иконка", "векторные иконки 16×16" do |ui, _i|
  ui.svg(SVG_ICON, size: Egui::Vec2.new(16.0, 16.0))
end

WidgetsBench.page "1000 × вложенный скролл (label)", "scrolledlabel со своим внутренним скроллом" do |ui, i|
  ui.scrolledlabel("Строка ##{i} — длинный текст во вложенном скролле " * 6,
    max_height: 48.0)
end

WidgetsBench.page "1000 × вложенный скролл (area)", "scroll_area внутри scroll_area" do |ui, i|
  ui.scroll_area(max_height: 60.0, scrollbar: :classic) do |inner|
    inner.label("Область ##{i}, строка 1 — внутренняя прокрутка")
    inner.label("Область ##{i}, строка 2")
    inner.label("Область ##{i}, строка 3")
    inner.label("Область ##{i}, строка 4")
    inner.label("Область ##{i}, строка 5")
  end
end

WidgetsBench.page "1000 × nested box", "box в box в box (глубокая вложенность)" do |ui, i|
  ui.box(fill: Egui::Color32.rgba(40, 44, 52, 255)) do |outer|
    outer.box(stroke: Egui::Color32.rgba(80, 86, 98, 255)) do |inner|
      inner.label("Вложенный ##{i}", userselect: false)
    end
  end
end

# -- progress + sorted report ---------------------------------------------------

only = ENV["ONLY"]?
cases = WidgetsBench::CASES.select { |c| !only || c.name.includes?(only) }

puts "widgets bench: #{cases.size} case'ов × #{N} элементов" \
     " · #{WIDTH.to_i}×#{HEIGHT.to_i} · warmup #{WARMUP} · frames #{FRAMES}"
if cases.empty?
  puts "ничего не выбрано (ONLY=#{only})"
  exit
end

results = [] of WidgetsBench::Result
cases.each_with_index do |kase, idx|
  STDOUT.print "[#{idx + 1} из #{cases.size}] #{kase.name} — #{kase.desc}… "
  STDOUT.flush
  result = WidgetsBench.run_case(kase)
  results << result
  if SCROLL_ONLY
    printf("%.2f ms/frame (скролл)\n", result.scroll_ms)
  else
    printf("%.2f ms/frame скролл · %.2f idle\n",
      result.scroll_ms, result.idle_ms)
  end
end

puts "\n== report — по убыванию нагрузки при скролле =="
if SCROLL_ONLY
  printf("  %10s  %6s  %6s  %s\n", "ms/frame", "fps", "cache", "case — desc")
else
  printf("  %10s  %6s  %10s  %6s  %s\n", "ms/frame", "fps",
    "idle ms", "cache", "case — desc")
end
results.sort_by! { |r| -r.load_ms }.each_with_index do |r, rank|
  fps = r.load_ms > 0.0 ? (1000.0 / r.load_ms).round.to_i : 0
  label = "#{r.kase.name} — #{r.kase.desc}"
  if SCROLL_ONLY
    printf("  %2d. %8.2f  %5d  %5.0f%%  %s\n",
      rank + 1, r.scroll_ms, fps, r.cache_hit, label)
  else
    printf("  %2d. %8.2f  %5d  %8.2f  %5.0f%%  %s\n",
      rank + 1, r.scroll_ms, fps, r.idle_ms, r.cache_hit, label)
  end
end
