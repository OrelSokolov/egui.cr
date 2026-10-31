# SideImage — the wizard watermark strip: an image pinned to a
# fixed-width column that stretches to whatever height the layout
# gives it. The WIDTH is capped (the declared strip width), the HEIGHT
# is not: the image fits inside the strip preserving its aspect
# (contain, top-aligned with padding) and the leftover column space
# carries a theme tint + a hairline edge, so it reads as chrome — the
# classic setup-wizard left column.
#
# Sources:
#   * an `Svg` — vector, rasterized at `ctx.pixels_per_point`, crisp
#     at every DPI (`Svg.load`, `Icon.from_file`);
#   * a raster file path (`SideImage.from_file` / `new(path)`) —
#     decoded once through `Context#load_image`, the aspect probed
#     from the file header; ship the source at least
#     `width × pixels_per_point` pixels to stay sharp on HiDPI.
#
#   step.side_image = Egui::SideImage.new(logo_svg)          # WizardStep
#   side.paint(ui, rect)                                     # anywhere
#
# Not a Widget: the height comes from the HOST layout (immediate
# mode cannot know it up front), so the container measures its
# content first and hands the strip a rect — exactly what Wizard's
# body does. Styling: `side_image` class rules (background).

module Egui
  class SideImage
    # Element class for `StyleSheet` tweaks from app code.
    CLASS = "side_image"

    # Strip width (the classic watermark column) and the image inset.
    DEFAULT_WIDTH = 164.0
    PAD           = 12.0

    getter width : Float64

    @source : Svg | String
    @texture = 0_u64
    @aspect = 0.0 # 0.0 = unknown yet (raster path, probed at paint)

    # `source`: an Svg (vector, DPI-crisp) or a raster image path.
    def initialize(source : Svg | String, @width : Float64 = DEFAULT_WIDTH)
      @source = source
      if source.is_a?(Svg)
        size = source.intrinsic_size
        @aspect = size.y > 0.0 ? size.x / size.y : 1.0
      end
    end

    # A raster image file; the texture loads lazily at first paint
    # (a Context exists there) and the aspect comes from the file's
    # header.
    def self.from_file(path : String, width : Float64 = DEFAULT_WIDTH) : self
      new(path, width)
    end

    # Draw the strip into `rect` (the caller-chosen column). The
    # background and the hairline edge always paint; the image rides
    # contain-fitted at the top.
    def paint(ui : Ui, rect : Rect) : Nil
      v = ui.style.visuals
      fill = ui.ctx.stylesheet.resolve(CLASS)
        .color("background", v.window_fill.lerp(v.text_color, 0.05))
      p = ui.painter
      p.rect(rect, 0.0, fill: fill)
      p.line(Pos2.new(rect.right - 0.5, rect.top),
        Pos2.new(rect.right - 0.5, rect.bottom), 1.0, v.separator_color)

      ctx = ui.ctx
      aspect = @aspect
      if aspect.zero? # raster path: probe the header once
        if (size = ctx.image_size(@source.as(String))) && size.y > 0.0
          aspect = @aspect = size.x / size.y
        else
          aspect = 1.0
        end
      end
      inner_w = {rect.width - 2 * PAD, 1.0}.max
      inner_h = {rect.height - 2 * PAD, 1.0}.max
      fit_w = inner_w
      fit_h = fit_w / aspect
      if fit_h > inner_h # too tall for the strip: cap by height
        fit_h = inner_h
        fit_w = fit_h * aspect
      end
      box = Rect.from_min_size(
        Pos2.new(rect.left + PAD + (inner_w - fit_w) / 2.0, rect.top + PAD),
        Vec2.new(fit_w, fit_h))
      if (svg = @source.as?(Svg))
        svg.paint(ui, box)
      else
        path = @source.as(String)
        @texture = ctx.load_image(path) if @texture.zero?
        if @texture.zero?
          p.rect(box, 3.0, fill: v.button_weak) # failed load placeholder
        else
          p.image(box, @texture)
        end
      end
    end
  end
end
