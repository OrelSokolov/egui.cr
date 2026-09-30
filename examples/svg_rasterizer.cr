# SVG rasterizer comparison: NanoSVG C (backend/nanosvg.cr via the C
# shim — a dev-build accelerator behind C_EXTENSIONS elsewhere, but
# this benchmark links it directly) vs the pure-Crystal NanoSVG port
# (nanosvg_cr.cr → the nanosvg shard, the primary rasterizer). The port
# is a faithful rewrite, so the interesting numbers are (a) do the two
# produce identical pixels and (b) what the Crystal speed costs.
# Icons cover both paint modes: filled paths (bootstrap) and stroked
# outlines (lucide).
#
#   bin/svg_rasterizer             # GUI: side by side, any size
#   bin/svg_rasterizer --headless  # console report (stats + ASCII) and exit
#
# Bootstrap Icons (MIT) live in icons/bootstrap, Lucide (ISC) in
# icons/lucide — Rakefile download:bootstrap refreshes them.

require "../src/egui"
require "../src/egui/backend/sokol"
# The C twin — the ONLY consumer of backend/nanosvg.cr: requiring it
# here links the nanosvg_shim object out of libegui_cr_sokol.a; all
# other apps bake through the Crystal port alone.
require "../src/egui/backend/nanosvg"
require "./icon"

ICONS = [
  {"bootstrap/4-square (filled paths)",
   "#{__DIR__}/../icons/bootstrap/4-square.svg"},
  {"bootstrap/airplane-engines (filled paths)",
   "#{__DIR__}/../icons/bootstrap/airplane-engines.svg"},
  {"lucide/save (stroked paths)",
   "#{__DIR__}/../icons/lucide/save.svg"},
]
TINT = Egui::Color32.rgb(0x33, 0x33, 0x33)

module SvgCompare
  RAMP = " .:-=+*#%@"
  # Single-shot timing: one bake per rasterizer, timed as it runs —
  # the GUI bakes once per size change, so the reported number should
  # match what a slider tick actually costs.
  RUNS = 1

  def self.coverage(buf : Bytes) : Float64
    covered = buf.each_slice(4).count { |(_, _, _, a)| a > 8 }
    covered.to_f64 / (buf.size / 4)
  end

  # Mean |Δα| and the share of pixels with |Δα| > 16 — how far the
  # port lands from the C original, pixel for pixel.
  def self.alpha_diff(a : Bytes, b : Bytes) : {Float64, Float64}
    return {0.0, 0.0} unless a.size == b.size
    total = 0_i64
    big = 0_i64
    npix = a.size // 4
    (0...npix).each do |i|
      d = (a[i * 4 + 3].to_i - b[i * 4 + 3].to_i).abs
      total += d
      big += 1 if d > 16
    end
    {total.to_f64 / npix, big.to_f64 / npix}
  end

  def self.best_ms : Float64
    best = Float64::MAX
    RUNS.times do
      t0 = Time.instant
      yield
      elapsed = (Time.instant - t0).total_milliseconds
      best = elapsed if elapsed < best
    end
    best
  end

  def self.ascii_preview(buf : Bytes, w : Int32, h : Int32,
                         cols : Int32 = 48) : String
    rows = cols // 2
    String.build do |s|
      rows.times do |ry|
        cols.times do |cx|
          px = cx * w // cols
          py = ry * h // rows
          a = buf[(py * w + px) * 4 + 3].to_i
          s << RAMP[a * (RAMP.size - 1) // 255]
        end
        s << '\n'
      end
    end
  end

  # One bake pair at one pixel size: both rasterizers ran on the same
  # source+tint, textures registered for the GUI panels.
  class Bake
    getter c_id = 0_u64
    getter cr_id = 0_u64
    getter c_ms = 0.0
    getter cr_ms = 0.0
    getter c_cov = 0.0
    getter cr_cov = 0.0
    getter diff_mean = 0.0
    getter diff_share = 0.0
    getter? identical = false
    getter? c_declined = false
    @size = 0

    def initialize(@source : String)
    end

    def pixels(size : Int32) : {Bytes, Bytes}
      # The parse is cached in NanoSvgCr, so time it as the widget
      # sees the pair: full C parse+rasterize vs port bake-from-cache
      # would not be a like-for-like first bake.
      Egui::NanoSvgCr.image(@source, TINT) # warm the port's parse cache

      c = nil
      c_ms = SvgCompare.best_ms do
        c = Egui::Backend::NanoSvg.rasterize(@source, TINT, size, size)
      end
      cr = nil
      cr_ms = SvgCompare.best_ms do
        cr = Egui::NanoSvgCr.rasterize(@source, TINT, size, size)
      end

      if c && cr
        @c_ms = c_ms
        @cr_ms = cr_ms
        @c_cov = SvgCompare.coverage(c)
        @cr_cov = SvgCompare.coverage(cr)
        @diff_mean, @diff_share = SvgCompare.alpha_diff(c, cr)
        @identical = c == cr
        {c, cr}
      else # C declined (no shapes): the widget falls through too
        @c_declined = true
        fb = (c || cr).not_nil!
        @c_cov = SvgCompare.coverage(fb)
        {fb, fb}
      end
    end

    def ensure(ctx : Egui::Context, size : Int32) : Nil
      return if @size == size && !@c_id.zero?
      if !@c_id.zero?
        ctx.textures.destroy_later(@c_id)
        ctx.textures.destroy_later(@cr_id)
      end
      c, cr = pixels(size)
      @c_id = ctx.textures.register_rgba(size, size, c)
      @cr_id = ctx.textures.register_rgba(size, size, cr)
      @size = size
      if ENV["SVG_COMPARE_DEBUG"]?
        s = GC.stats
        STDERR.puts sprintf("dbg bake %dx%d: C %.2f ms, Crystal %.2f ms, heap %dM",
          size, size, @c_ms, @cr_ms, s.heap_size // 1048576)
      end
    end
  end
end

def svg_compare_report(size : Int32 = 128) : Nil
  # Timings from a non-release build are meaningless: the C shim is
  # cc -O2 either way, but the Crystal port's hot loops need LLVM -O3
  # (10-100x without — the rake build:dev footgun).
  {% unless flag?(:release) %}
    puts "WARNING: built WITHOUT --release — Crystal timings below are " \
         "10-100x inflated. Rebuild via `rake build:examples`."
  {% end %}
  ICONS.each do |name, path|
    src = File.read(path)
    bake = SvgCompare::Bake.new(src)
    c, cr = bake.pixels(size)
    puts "==> #{name}  (#{File.basename(path)}, #{size}×#{size}, " \
         "fill=currentColor tinted ##{"%02x%02x%02x" % {TINT.r, TINT.g, TINT.b}})"
    if bake.c_declined?
      puts "    C shim: parse declined — both panels below are the Crystal port"
    end
    puts "    C       : #{"%.2f" % bake.c_ms} ms, coverage " \
         "#{"%.1f" % (bake.c_cov * 100)}%"
    puts "    Crystal : #{"%.2f" % bake.cr_ms} ms, coverage " \
         "#{"%.1f" % (bake.cr_cov * 100)}%"
    puts "    diff    : #{"%.1f" % (bake.diff_share * 100)}% of pixels " \
         "(|Δα|>16), mean |Δα| #{"%.1f" % bake.diff_mean}, " \
         "bytes identical: #{bake.identical? ? "yes" : "no"}"
    puts "-- NanoSVG C --"
    print SvgCompare.ascii_preview(c, size, size)
    puts "-- NanoSVG Crystal --"
    print SvgCompare.ascii_preview(cr, size, size)
    puts
  end
end

class SvgRasterizerApp < Egui::App
  @size = 192.0_f64
  @bakes = {} of String => SvgCompare::Bake

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("SVG rasterizer — NanoSVG C vs Crystal port")
      {% unless flag?(:release) %}
      ui.label("WARNING: dev build — Crystal bake timings are 10-100x " \
               "inflated. Rebuild via `rake build:examples`.")
      {% end %}
      ui.label("Same library, two implementations: the C shim is the " \
               "primary bake, the pure-Crystal port the fallback. " \
               "Compare pixels and bake time.")
      ui.separator
      ui.horizontal do |row|
        row.label("size:")
        row.slider(@size, 48.0..512.0) { |v| @size = v }
        # The bake runs at PHYSICAL pixels (the Svg#paint rule), so a
        # 2x display quadruples the area — bake time grows ~quadratically.
        # Show both or "0.5 ms vs 16 ms" looks like a mystery.
        ppp = ctx.pixels_per_point
        px = (@size * ppp).round.to_i
        suffix = ppp == 1.0 ? "" : " @#{ppp}x display"
        row.label("#{"%.0f" % @size} px → bakes " \
                  "#{"%.0f" % px}×#{"%.0f" % px}#{suffix}")
      end

      ICONS.each do |name, path|
        bake = (@bakes[name] ||= SvgCompare::Bake.new(File.read(path)))
        # Bake at whole physical pixels: the quad then lands 1:1
        # texel-to-pixel, no resampling smear.
        ppp = ctx.pixels_per_point
        px = (@size * ppp).round.to_i
        bake.ensure(ctx, px)
        ui.separator
        ui.label(name)
        ui.columns(2) do |cols|
          w = px / ppp
          stats_c = format_stats(bake.c_ms, bake.c_cov)
          stats_cr = format_stats(bake.cr_ms, bake.cr_cov)
          panel(cols[0], "NanoSVG C (primary)", bake.c_id, stats_c, w, bake)
          panel(cols[1], "NanoSVG Crystal (port)", bake.cr_id, stats_cr, w, bake)
        end
      end
    end
  end

  private def format_stats(ms : Float64, cov : Float64) : String
    "#{"%.2f" % ms} ms bake · #{"%.1f" % (cov * 100)}% coverage"
  end

  # White card + the baked texture at exactly the baked pixel size.
  private def panel(ui : Egui::Ui, title : String, id : UInt64,
                    stats : String, w : Float64,
                    bake : SvgCompare::Bake) : Nil
    ui.label(title)
    rect = ui.allocate_at_least(Egui::Vec2.new(w, w))
    ui.painter.rect(rect, 8.0, fill: Egui::Color32.new(255, 255, 255, 255))
    ui.painter.image(rect, id) unless id.zero?
    ui.interact(rect, ui.next_widget_id, Egui::Sense.none)
    ui.label(stats)
    ui.label("vs C: #{"%.1f" % (bake.diff_share * 100)}% differing pixels" \
             "#{" · identical" if bake.identical?}")
  end
end

if ARGV.includes?("--headless")
  svg_compare_report
  exit 0
end

Egui::Backend::Sokol.run(SvgRasterizerApp.new,
  title: "egui-cr — SVG rasterizer comparison",
  width: 760, height: 860,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64}, inspector: :hidden)
