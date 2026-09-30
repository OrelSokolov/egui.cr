# C NanoSVG binding (vendor/nanosvg via the nanosvg_shim C helpers) —
# NOT part of the release rasterization path. The Svg texture bake
# (widgets/svg.cr) runs through the pure-Crystal port (nanosvg_cr.cr);
# this module serves two comparison/dev roles:
#   * backend/sokol.cr installs it as Svg.external_rasterizer in DEV
#     builds (no --release) — C is cc -O2 always, the port's hot
#     loops are 10-100x slower unoptimized;
#   * examples/svg_rasterizer.cr requires it directly for A/B timing
#     (and thereby links the nanosvg_shim object from
#     libegui_cr_sokol.a — apps that never require this file don't
#     pull the object in, since nothing references its symbols).
#
# Contract twin of NanoSvgCr.rasterize: same pre-bake rewrite (via
# NanoSvgCr.prepare), same fit — the parsed image (viewBox already
# applied by NanoSVG) is scaled with the aspect preserved and
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
        # Shared pre-bake rewrite with the Crystal port: tint +
        # bbox-relative gradient coordinates.
        src = NanoSvgCr.prepare(source, tint)

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
    end
  end
end
