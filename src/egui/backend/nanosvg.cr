# Primary SVG rasterization backend: NanoSVG (vendor/nanosvg) via the
# nanosvg_shim C helpers. Installed as Egui::Svg.external_rasterizer —
# the Svg texture bake calls it first and falls back to the built-in
# software rasterizer (widgets/svg.cr #rasterize) when it declines a
# source, exactly the FreetypeFonts/LightHintedFonts split of the font
# stack. Headless builds never require this file, so specs keep
# exercising the built-in rasterizer and the vector paint path.
#
# NanoSVG brings what the built-in rasterizer lacks: real polygon
# fills (a filled path no longer degrades to a stroked outline),
# gradients in any orientation, nested groups with transforms, dash
# arrays and shape/group opacity. Both rasterizers share the same
# limitations for icon-style art: <text> is ignored.
#
# Layout matches the widget's own fit: the parsed image (viewBox
# already applied by NanoSVG) is scaled with the aspect preserved and
# centered in the target bitmap, like `<img>` object-fit.

@[Link("egui_cr_sokol")]
lib LibNanoSvg
  fun parse = egui_cr_svg_parse(input : UInt8*, dpi : Float32) : Void*
  fun free = egui_cr_svg_free(image : Void*) : Void
  fun size = egui_cr_svg_size(image : Void*, w : Float32*, h : Float32*) : Void
  fun rasterize = egui_cr_svg_rasterize(image : Void*, tx : Float32, ty : Float32,
                                        scale : Float32, dst : UInt8*,
                                        w : Int32, h : Int32) : Int32
end

module Egui
  module Backend
    module NanoSvg
      DPI = 96.0_f32

      # Rasterize `source` into a w×h straight-alpha RGBA8 bitmap, or
      # nil when NanoSVG cannot parse it (shim returns NULL — see
      # backend/nanosvg_shim.c for the no-shapes rule). `tint`
      # resolves `currentColor` occurrences before parsing; the input
      # is copied because nsvgParse edits its buffer in place.
      def self.rasterize(source : String, tint : Color32,
                         w : Int32, h : Int32) : Bytes?
        hex = "#%02x%02x%02x" % [tint.r, tint.g, tint.b]
        src = bbox_gradient_percentages(source)
             .gsub(/currentColor/i) { hex }

        # Private mutable NUL-terminated copy for nsvgParse.
        buf = Bytes.new(src.bytesize + 1)
        buf.copy_from(src.to_unsafe, src.bytesize)

        image = LibNanoSvg.parse(buf, DPI)
        return nil unless image
        begin
          iw = uninitialized Float32
          ih = uninitialized Float32
          LibNanoSvg.size(image, pointerof(iw), pointerof(ih))
          return nil if iw <= 0.0 || ih <= 0.0
          scale = {w / iw, h / ih}.min
          tx = (w - iw * scale) / 2.0
          ty = (h - ih * scale) / 2.0
          dst = Bytes.new(w * h * 4)
          if LibNanoSvg.rasterize(image, tx, ty, scale, dst, w, h) == 1
            dst
          end
        ensure
          LibNanoSvg.free(image)
        end
      end

      # NanoSVG reads gradient coordinates as user-space units unless
      # they carry a "%" suffix, but the SVG spec default
      # (gradientUnits="objectBoundingBox") makes unitless numbers
      # fractions of the shape's bbox — assets/icon.svg-style
      # gradients (`y2="1"`) would collapse to a 1-user-unit ramp.
      # Rewrite unitless x1/y1/x2/y2/cx/cy/r/fx/fy in gradients
      # without explicit userSpaceOnUse to the equivalent
      # percentages, which NanoSVG interprets bbox-relative.
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
end

# Install as the Svg bake's primary rasterizer. Required from
# backend/sokol.cr next to ./freetype, so every graphical app gets it
# while headless/spec builds keep the built-in fallback.
rasterizer = ->Egui::Backend::NanoSvg.rasterize(String, Egui::Color32, Int32, Int32)
Egui::Svg.external_rasterizer = rasterizer
