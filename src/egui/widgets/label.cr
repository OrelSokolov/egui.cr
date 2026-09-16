# Port of egui_upstream/crates/egui/src/widgets/label.rs.
#
# A Label reserves its text size, paints the text, and returns a
# (non-clickable) Response — upstream `Sense::hover()`. Accepts a
# String or RichText; `wrap` lays the text out with greedy word-wrap
# against the available width (egui `Label::wrap`).
#
# Alignment (CSS `text-align`): an aligned label (:center/:right) is
# a block — it reserves the full available width of its Ui and paints
# the galley at the aligned x, like a centered <p>. The value comes
# from the label itself, `RichText#align`, the per-widget
# `WidgetStyle#text_align` override, or the theme default.

module Egui
  class Label
    include Widget

    getter rich : RichText
    getter? wrap : Bool

    def initialize(text : String, size : Float64? = nil, wrap : Bool = false,
                   align : Symbol? = nil)
      @rich = RichText.new(text)
      @rich.size(size) if size
      @rich.align(align) if align
      @wrap = wrap
    end

    def initialize(@rich : RichText, wrap : Bool = false)
      @wrap = wrap
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      runs = @rich.runs(style.font_size, style.visuals.text_color)
      align = @rich.align || style.text_align
      block = align && align != :left
      max_width = @wrap ? ui.available_width : nil
      galley = ui.ctx.fonts.layout(runs, max_width)

      # A centered/right-aligned label is block-level: it takes the
      # full row width so the alignment is visible.
      size = galley.size
      size = Vec2.new({size.x, ui.available_width}.max, size.y) if block
      rect = ui.allocate_at_least(size)
      pos = rect.min
      if block
        spare = rect.width - galley.size.x
        pos = Pos2.new(
          align == :center ? rect.left + spare / 2.0 : rect.right - galley.size.x,
          rect.min.y)
      end

      id = ui.next_widget_id
      ui.painter.paint_galley(pos, galley, ui.ctx.fonts,
        style.visuals.text_color)

      ui.interact(rect, id, Sense.none)
    end
  end
end
