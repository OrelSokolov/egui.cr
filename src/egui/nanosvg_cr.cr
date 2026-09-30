# Pure-Crystal NanoSVG rasterizer — the ../nanosvg.cr shard, a
# faithful port of the C library (byte-identical output on the test
# artwork). Contract twin of backend/nanosvg.cr (the C shim):
# `rasterize(source, tint, w, h)` → straight-alpha RGBA8 bytes, or
# nil when the source has no usable intrinsic size.
#
# The Svg texture bake (widgets/svg.cr) calls the C rasterizer first
# when the native backend is linked and falls back to THIS module —
# the freetype.cr/text.cr primary/fallback split, except the
# fallback is now the full NanoSVG feature set (polygon fills,
# gradients, nested transforms, dashes) instead of the deleted
# built-in distance-field rasterizer. Pure Crystal, so headless
# builds and specs rasterize identically to the GUI.
#
# Parsed images are memoized per (source, tint): Svg#paint needs the
# intrinsic size every frame while `ui.svg` builds a fresh Svg per
# frame, and re-parsing on every cache-miss bake would be waste —
# the cache is bounded by the set of distinct icon sources an app
# uses (Icon.from_file memoizes the same key one level up).

require "nanosvg"

module Egui
  module NanoSvgCr
    DPI = 96.0_f32

    @@images = {} of {String, Color32} => NanoSVG::Image

    # Parsed (viewBox applied, `currentColor` resolved) image, or nil
    # for a source NanoSVG cannot give an intrinsic size.
    def self.image(source : String, tint : Color32) : NanoSVG::Image?
      unless (img = @@images[{source, tint}]?)
        parsed = NanoSVG.parse(prepare(source, tint), "px", DPI)
        return nil if parsed.width <= 0.0_f32 || parsed.height <= 0.0_f32
        img = @@images[{source, tint}] = parsed
      end
      img
    end

    # Rasterize `source` into a w×h straight-alpha RGBA8 bitmap
    # (same fit as the C backend: aspect preserved, centered —
    # `<img>` object-fit), or nil when the source is unusable.
    def self.rasterize(source : String, tint : Color32,
                       w : Int32, h : Int32) : Bytes?
      image = image(source, tint)
      return nil unless image
      iw = image.width
      ih = image.height
      scale = {w / iw, h / ih}.min
      tx = ((w - iw * scale) / 2.0).to_f32
      ty = ((h - ih * scale) / 2.0).to_f32
      # One-shot rasterizer context: bakes are cache misses only, so
      # there is nothing to gain from keeping one alive (same call
      # pattern as the C shim's parse/rasterize pair).
      NanoSVG::Rasterizer.rasterize(image, tx, ty, scale, w, h)
    end

    # Shared pre-bake rewrite (the C backend runs it too): resolve
    # `currentColor` to the tint, then the gradient-coordinate fix.
    def self.prepare(source : String, tint : Color32) : String
      hex = "#%02x%02x%02x" % [tint.r, tint.g, tint.b]
      bbox_gradient_percentages(source)
           .gsub(/currentColor/i) { hex }
    end

    # NanoSVG reads gradient coordinates as user-space units unless
    # they carry a "%" suffix, but the SVG spec default
    # (gradientUnits="objectBoundingBox") makes unitless numbers
    # fractions of the shape's bbox — assets/icon.svg-style
    # gradients (`y2="1"`) would collapse to a 1-user-unit ramp.
    # Rewrite unitless x1/y1/x2/y2/cx/cy/r/fx/fy in gradients
    # without explicit userSpaceOnUse to the equivalent percentages,
    # which NanoSVG interprets bbox-relative.
    private def self.bbox_gradient_percentages(src : String) : String
      src.gsub(/<(?:linear|radial)Gradient\b[^>]*>/) do |tag|
        next tag if tag.includes?("userSpaceOnUse")
        tag.gsub(/(\b(?:x1|y1|x2|y2|cx|cy|r|fx|fy))\s*=\s*(["'])(-?\d+(?:\.\d+)?(?:[eE]-?\d+)?)\2/i) do
          "#{$1}=\"#{$3.to_f64 * 100}%\""
        end
      end
    end
  end
end
