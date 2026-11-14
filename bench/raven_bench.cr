# egui.cr analog of Raven's tests/benchmark.c (tmp/Raven) — the CPU
# cost of a large widget tree, headless (null backend: no FFI, no GPU).
#
#   crystal build bench/raven_bench.cr -o bin/benchmarks/raven_bench \
#     --release && ./bin/benchmarks/raven_bench [columns]
#
# Same tree as raven_benchmark: `columns` x 60 rows, each row a
# bordered line with a label ("Item c.r") and a button ("x"), laid out
# as columns of rows inside a scroll area — nothing is culled.
#
# Raven is retained (build the tree once, then layout/paint frames);
# egui.cr is immediate — the tree is re-declared every frame and the
# paint cache replays unchanged subtrees. So the Raven rows map to:
#
#   build         — constructing the ~12k widget objects (allocation
#                   only; in a real app this cost is inside update)
#   first layout  — the FIRST frame end to end (declare + layout +
#                   paint with cold caches — this rasterizes glyphs
#                   and fills every cache; immediate mode has no
#                   separate layout pass to time)
#   repaint       — a steady-state frame, best of 30: primitives are
#                   the emitted PaintCmds, rebuilt/replayed is the
#                   paint-cache damage report
#   relayout      — the whole frame after changing one label's text
#                   (the same cell Raven pokes: column 3, row 7)

require "../src/egui"
require "../src/egui/driver/crystalfonts"

COLUMNS = (ARGV[0]? || "40").to_i.clamp(4..)
ROWS    = 60
FRAMES  = 30

class RavenTreeApp < Egui::App
  getter nodes = 0

  @texts : Array(Array(String))

  def initialize(columns : Int32)
    super()
    @texts = Array.new(columns) { |c| Array.new(ROWS) { |r| "Item #{c}.#{r}" } }
  end

  # The same poke as benchmark.c: column 3, row 7, the row's label.
  def poke_label : Nil
    @texts[3][7] = "a longer text than before"
  end

  def update(ctx : Egui::Context) : Nil
    ctx.request_repaint
    @nodes = 0
    ctx.central_panel do |ui|
      stroke = ui.style.visuals.window_stroke
      ui.scroll_area do |scroll|
        @nodes += 1 # the scroll area
        scroll.columns(@texts.size) do |cols|
          @nodes += 1 # the row of columns
          cols.each_with_index do |col, ci|
            @nodes += 1 # the column
            @texts[ci].each do |text|
              col.box(:row, stroke: stroke,
                      margin: Egui::Vec2.new(4.0, 2.0)) do |line|
                @nodes += 3 # bordered line + label + button
                line.label(text, wrap: false)
                line.add(Egui::Button.new("x"))
              end
            end
          end
        end
      end
    end
  end
end

# Real font stack (what a shipped app runs with): the headless
# monospace estimate would make measure() free and the bench would
# measure a different program than the one shipping.
def bench_font : Egui::Driver::CrystalFonts?
  paths = Egui::SystemPorts::Fonts.search_paths
  return nil if paths.empty?
  Egui::Driver::CrystalFonts.from_system(paths)
end

record FrameRun, total_ms : Float64, primitives : Int32,
                  rebuilt : Int32, replayed : Int32

def run_frame(app : Egui::App, screen : Egui::Rect, time : Float64) : FrameRun
  raw = Egui::RawInput.new(screen, [] of Egui::Event, time)
  t0 = Time.instant
  app.ctx.begin_frame(raw)
  app.update(app.ctx)
  cmds = app.ctx.end_frame
  total = (Time.instant - t0).total_milliseconds
  FrameRun.new(total, cmds.size, app.ctx.frame_rebuilt, app.ctx.frame_replayed)
end

app = RavenTreeApp.new(COLUMNS)
if Egui::NoopFonts.selected?
  puts "fonts: NOOP (EGUI_NOFONTS) — geometry from the estimate, nothing renders"
elsif (font = bench_font)
  app.ctx.fonts = font
else
  puts "fonts: NONE — headless monospace estimate (measure() unrealistic)"
end
puts "svg:   NOOP (EGUI_NOSVG) — blank rasters" if Egui::Svg.noop_selected?
puts "cache: OFF (EGUI_NOCACHE) — every widget runs for real each frame" if Egui::PaintCache.disabled?
# Same texture stand-in Bench.run installs: Svg-heavy paths bake like
# in production (this tree has none, but the registry must be set).
app.ctx.textures = Egui::Bench::GraphicalTextureRegistry.new

# Raven sizes the null window so every widget is visible: nothing is
# culled. egui.cr scroll areas build every row regardless of the
# viewport, but the paint cache only stores clip-contained captures —
# so the default viewport fits the whole tree (60 rows ≈ 2.4k px);
# BENCH_H shrinks it to measure the clip-culled tail.
screen = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(150.0 * COLUMNS, (ENV["BENCH_H"]? || "2600").to_f64))

# build: widget-object construction alone (the retained half of
# Raven's build; egui.cr normally constructs these inside update).
t0 = Time.instant
COLUMNS.times do |c|
  ROWS.times do |r|
    Egui::Label.new("Item #{c}.#{r}", wrap: false)
    Egui::Button.new("x")
  end
end
build_ms = (Time.instant - t0).total_milliseconds

gc0 = GC.stats.total_bytes
first = run_frame(app, screen, 1.0 / 60.0)
first_alloc = GC.stats.total_bytes - gc0
puts "#{app.nodes} widget nodes, #{COLUMNS} columns × #{ROWS} rows — " \
     "egui.cr headless (null backend)"
printf("  build         %8.2f ms   (widget objects; immediate mode re-declares them every frame)\n", build_ms)
printf("  first layout  %8.2f ms   (first frame: declare + layout + paint, cold — rasterizes the glyphs; %d KB allocated)\n",
  first.total_ms, first_alloc // 1024)
printf("               %8d primitives, %d rebuilt + %d replayed (paint cache)\n",
  first.primitives, first.rebuilt, first.replayed)

best = 1e9
sum = 0.0
last = first
gc0 = GC.stats.total_bytes
FRAMES.times do |i|
  last = run_frame(app, screen, (i + 2) / 60.0)
  best = {best, last.total_ms}.min
  sum += last.total_ms
end
alloc_per_frame = (GC.stats.total_bytes - gc0) // FRAMES
printf("  repaint       %8.2f ms   best of %d (average %.2f ms): %d primitives, %d rebuilt + %d replayed, %d KB/frame allocated\n",
  best, FRAMES, sum / FRAMES, last.primitives, last.rebuilt, last.replayed, alloc_per_frame // 1024)

app.poke_label
poke = run_frame(app, screen, (FRAMES + 2) / 60.0)
printf("  relayout      %8.3f ms   after changing one label (%d rebuilt + %d replayed)\n",
  poke.total_ms, poke.rebuilt, poke.replayed)
