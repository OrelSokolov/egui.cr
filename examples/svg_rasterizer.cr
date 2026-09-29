# SVG rasterizer comparison on Bootstrap icons: NanoSVG (the primary
# external rasterizer, backend/nanosvg.cr) vs the built-in software
# fallback (widgets/svg.cr #rasterize). The icons are filled-path
# artwork — the case where the two diverge the most: NanoSVG fills
# polygons, the fallback (no tessellation in the vector backend)
# degrades a filled path to stroking its outline in the fill color.
#
#   bin/svg_rasterizer             # GUI: side by side, any size
#   bin/svg_rasterizer --headless  # console report (stats + ASCII) and exit
#
# Bootstrap Icons (MIT) live in icons/bootstrap — Rakefile
# download:bootstrap refreshes them.

require "../src/egui"
require "../src/egui/backend/sokol"
require "./icon"

ICONS = [
  {"4-square", "#{__DIR__}/../icons/bootstrap/4-square.svg"},
  {"airplane-engines", "#{__DIR__}/../icons/bootstrap/airplane-engines.svg"},
]
TINT = Egui::Color32.rgb(0x33, 0x33, 0x33)

module SvgCompare
  RAMP = " .:-=+*#%@"

  def self.coverage(buf : Bytes) : Float64
    covered = buf.each_slice(4).count { |(_, _, _, a)| a > 8 }
    covered.to_f64 / (buf.size / 4)
  end

  # Mean |Δalpha| and the share of pixels with |Δalpha| > 16 — how
  # far the fallback lands from the primary, pixel for pixel.
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
    getter nano_id = 0_u64
    getter fallback_id = 0_u64
    getter nano_ms = 0.0
    getter fallback_ms = 0.0
    getter nano_cov = 0.0
    getter fallback_cov = 0.0
    getter diff_mean = 0.0
    getter diff_share = 0.0
    @size = 0

    def initialize(@source : String)
    end

    def pixels(size : Int32) : {Bytes, Bytes}
      t0 = Time.instant
      nano = Egui::Backend::NanoSvg.rasterize(@source, TINT, size, size)
      t_nano = (Time.instant - t0).total_milliseconds
      t0 = Time.instant
      # The fallback path the way the widget would take it: parse with
      # the built-in parser, then its software rasterize.
      fallback = Egui::Svg.new(@source,
        current_color: TINT).rasterize(size, size)
      t_fb = (Time.instant - t0).total_milliseconds

      if nano # NanoSVG parsed it — the normal primary outcome
        @nano_ms = t_nano
        @fallback_ms = t_fb
        @nano_cov = SvgCompare.coverage(nano)
        @fallback_cov = SvgCompare.coverage(fallback)
        @diff_mean, @diff_share = SvgCompare.alpha_diff(nano, fallback)
        {nano, fallback}
      else # primary declined: the widget would fall through too
        @fallback_ms = t_fb
        @fallback_cov = SvgCompare.coverage(fallback)
        {fallback, fallback}
      end
    end

    def ensure(ctx : Egui::Context, size : Int32) : Nil
      return if @size == size && !@nano_id.zero?
      if !@nano_id.zero?
        ctx.textures.destroy_later(@nano_id)
        ctx.textures.destroy_later(@fallback_id)
      end
      nano, fallback = pixels(size)
      @nano_id = ctx.textures.register_rgba(size, size, nano)
      @fallback_id = ctx.textures.register_rgba(size, size, fallback)
      @size = size
    end
  end
end

def svg_compare_report(size : Int32 = 128) : Nil
  ICONS.each do |name, path|
    src = File.read(path)
    bake = SvgCompare::Bake.new(src)
    nano, fallback = bake.pixels(size)
    puts "==> #{name}  (#{File.basename(path)}, #{size}×#{size}, " \
         "fill=currentColor tinted ##{"%02x%02x%02x" % {TINT.r, TINT.g, TINT.b}})"
    if bake.nano_id.zero? && nano.same?(fallback)
      puts "    NanoSVG: parse declined — both panels below are the built-in fallback"
    end
    puts "    NanoSVG  : #{"%.2f" % bake.nano_ms} ms, coverage " \
         "#{"%.1f" % (bake.nano_cov * 100)}%"
    puts "    fallback : #{"%.2f" % bake.fallback_ms} ms, coverage " \
         "#{"%.1f" % (bake.fallback_cov * 100)}%"
    puts "    diff     : #{"%.1f" % (bake.diff_share * 100)}% of pixels " \
         "(|Δα|>16), mean |Δα| #{"%.1f" % bake.diff_mean}"
    puts "-- NanoSVG --"
    print SvgCompare.ascii_preview(nano, size, size)
    puts "-- built-in fallback --"
    print SvgCompare.ascii_preview(fallback, size, size)
    puts
  end
end

class SvgRasterizerApp < Egui::App
  @size = 192.0_f64
  @bakes = {} of String => SvgCompare::Bake

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("SVG rasterizer — NanoSVG vs built-in fallback")
      ui.label("Bootstrap icons (filled paths): the primary fills " \
               "polygons; the fallback strokes outlines — no " \
               "tessellation in the vector backend.")
      ui.separator
      ui.horizontal do |row|
        row.label("size:")
        row.slider(@size, 48.0..512.0) { |v| @size = v }
        row.label("#{"%.0f" % @size} px")
      end

      ICONS.each do |name, path|
        bake = (@bakes[name] ||= SvgCompare::Bake.new(File.read(path)))
        # Bake at whole physical pixels (the Svg#paint rule): the quad
        # then lands 1:1 texel-to-pixel, no resampling smear.
        ppp = ctx.pixels_per_point
        px = (@size * ppp).round.to_i
        bake.ensure(ctx, px)
        ui.separator
        ui.label(name)
        ui.columns(2) do |cols|
          w = px / ppp
          stats_n = format_stats(bake.nano_ms, bake.nano_cov)
          stats_f = format_stats(bake.fallback_ms, bake.fallback_cov)
          panel(cols[0], "NanoSVG (primary)", bake.nano_id, stats_n, w, bake)
          panel(cols[1], "built-in fallback", bake.fallback_id, stats_f, w, bake)
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
    ui.label("vs #{"%.1f" % (bake.diff_share * 100)}% differing pixels")
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
