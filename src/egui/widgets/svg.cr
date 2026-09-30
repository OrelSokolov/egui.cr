# An SVG widget: parse once for the intrinsic (viewBox-applied)
# size, then replay the art as ONE cached raster texture per
# (source, tint, pixel size) — the font-atlas approach applied to
# vector art. There is no vector paint path and no C rasterizer in
# release builds: the bake runs through NanoSvgCr (nanosvg_cr.cr,
# the pure-Crystal NanoSVG port) — polygon fills, gradients in any
# orientation, nested transforms, dash arrays, shape/group opacity.
# DEV builds (no --release) route the bake through the C twin
# instead — see backend/sokol.cr; output is byte-identical either
# way. (backend/nanosvg.cr is also required directly by
# examples/svg_rasterizer for A/B timing.)
#
# Shared limitation (NanoSVG's): <text> is ignored — logo artwork
# relying on SVG text should ship it pre-converted to paths.
#
# Icon-set conventions: `currentColor` resolves to the
# `current_color` parse argument (BLACK by default —
# `Icon.from_file` passes its `tint:` there).
#
# Headless (non-graphical TextureRegistry) builds allocate the
# widget rect but paint nothing — there is no GPU texture to
# upload, and specs assert on the bake buffers instead.

module Egui
  class Svg
    include Widget

    # Default `currentColor` resolution (the parse argument below).
    BLACK = Color32.rgb(0, 0, 0)

    # Square widget by default — the common logo shape.
    property size : Vec2

    @source : String
    @current_color : Color32
    # Intrinsic size in user units (viewBox already applied by
    # NanoSVG) — drives the aspect-preserving fit of the quad.
    @width : Float64
    @height : Float64

    # `current_color` resolves `currentColor` in the source (icon
    # sets are monochrome; pass the theme fg here).
    def initialize(source : String, @size : Vec2 = Vec2.new(128.0, 128.0),
                   current_color : Color32 = BLACK)      @source = source
      @current_color = current_color
      if (img = NanoSvgCr.image(source, current_color))
        @width = img.width.to_f64
        @height = img.height.to_f64
      else # unusable source: a 100×100 box, like a bare <svg> with no viewBox
        @width = 100.0
        @height = 100.0
      end
    end

    # From a file on disk (e.g. assets/icon.svg).
    def self.load(path : String, size : Vec2 = Vec2.new(128.0, 128.0)) : self
      new(File.read(path), size)
    end

    def ui(ui : Ui) : Response
      rect = ui.allocate_at_least(@size)
      paint(ui, rect)
      ui.interact(rect, ui.next_widget_id, Sense.none)
    end

    # Fit the intrinsic size into `rect` (aspect preserved,
    # centered) and replay the art as one textured quad.
    #
    # The raster texture is software-baked ONCE per (source, tint,
    # pixel size) with anti-aliasing (MAX_RASTER_SIZES bounds the
    # bakes per icon so a size slider evicts the oldest instead of
    # accumulating). Raster and quad are DERIVED from each other:
    # bake at whole physical pixels, then draw the quad at exactly
    # that many pixels, snapped to the pixel grid — a 1:1
    # texel-to-pixel mapping samples without resampling blur. This
    # is why fonts are crisp: they rasterize at their exact ppem and
    # land 1:1. (A quad of 44.2 px sampling a 45-texel raster smears
    # every texel into its neighbor — the "soapy icon" look.)
    MAX_RASTER_SIZES = 8
    # Global budget across ALL Svgs (GPU memory + the sokol image
    # pool): past it the oldest bake is destroyed FIFO — scrolled-away
    # icons re-bake on return (~a millisecond each), memory stays
    # bounded whatever the app does. Sized to hold the full lucide
    # set (~1850) plus headroom: sokol frees destroyed image slots a
    # few frames LATE, so a budget below the working set makes rapid
    # eviction churn exhaust the pool even with the cap respected
    # (the LUCIDE_NO_CULL stress lesson).
    MAX_RASTER_TEXTURES = 2000
    @@raster_cache = {} of {String, Color32} =>
      Array(Tuple(Int32, Int32, UInt64))
    @@raster_order = [] of Tuple({String, Color32}, UInt64)

    # Optional primary rasterizer: (source, tint, w, h) →
    # straight-alpha RGBA8 bytes, or nil to use NanoSvgCr. backend/
    # sokol.cr installs the C NanoSVG shim here in DEV builds only
    # (no --release): the C code is cc -O2 regardless of Crystal's
    # flags, while the port's hot loops are 10-100x slower unoptimized
    # — the release build stays pure Crystal.
    class_property external_rasterizer : Proc(String, Color32, Int32,
      Int32, Bytes?) | ::Nil = nil

    def paint(ui : Ui, rect : Rect) : Nil
      Egui::Bench.span("Svg#paint") { paint_body(ui, rect) }
    end

    private def paint_body(ui : Ui, rect : Rect) : Nil
      return unless ui.ctx.textures.graphical?
      painter = ui.painter
      scale = {rect.width / @width, rect.height / @height}.min
      fit_w = @width * scale
      fit_h = @height * scale
      ppp = ui.ctx.pixels_per_point
      tw = {(fit_w * ppp).round.to_i, 1}.max
      th = {(fit_h * ppp).round.to_i, 1}.max
      return if (id = raster_texture(ui.ctx.textures, tw, th)).zero?
      qw = tw / ppp
      qh = th / ppp
      cx = rect.left + rect.width / 2.0
      cy = rect.top + rect.height / 2.0
      x0 = (((cx - qw / 2.0) * ppp).round) / ppp
      y0 = (((cy - qh / 2.0) * ppp).round) / ppp
      painter.image(Rect.from_min_size(Pos2.new(x0, y0),
        Vec2.new(qw, qh)), id)
    end

    # Cache lookup/bake for #paint's textured path. Keyed by
    # (source, tint) with per-size entries — the "invalidate on size
    # change" contract, same as the font atlas per-ppem rebake.
    private def raster_texture(registry : TextureRegistry,
                               w_px : Int32, h_px : Int32) : UInt64
      key = {@source, @current_color}
      sizes = (@@raster_cache[key] ||= [] of Tuple(Int32, Int32, UInt64))
      sizes.each do |tw, th, id|
        if !id.zero? && tw == w_px && th == h_px
          Egui::Bench.count("svg.raster.hit")
          return id
        end
      end
      Egui::Bench.count("svg.raster.miss")
      pixels = if (raster = Svg.external_rasterizer) &&
                   (bytes = raster.call(@source, @current_color, w_px, h_px))
        Egui::Bench.count("svg.raster.external")
        bytes
      elsif (bytes = NanoSvgCr.rasterize(@source, @current_color, w_px, h_px))
        Egui::Bench.count("svg.raster.crystal")
        bytes
      else
        return 0_u64
      end
      id = Egui::Bench.span("Svg#rasterize") do
        registry.register_rgba(w_px, h_px, pixels)
      end
      return 0_u64 if id.zero?
      if sizes.size >= MAX_RASTER_SIZES
        old = sizes.shift?
        if old && !old[2].zero?
          registry.destroy_later(old[2])
          @@raster_order.reject! { |_, oid| oid == old[2] }
        end
      end
      while @@raster_order.size >= MAX_RASTER_TEXTURES
        old_key, old_id = @@raster_order.shift
        if (arr = @@raster_cache[old_key]?)
          arr.reject! { |_, _, oid| oid == old_id }
          @@raster_cache.delete(old_key) if arr.empty?
        end
        # destroy_later, not destroy: an earlier cell this frame may
        # already have emitted an ImageCmd for this id (see
        # TextureRegistry#destroy_later).
        registry.destroy_later(old_id) unless old_id.zero?
      end
      sizes << {w_px, h_px, id}
      @@raster_order << {key, id}
      id
    end
  end
end
