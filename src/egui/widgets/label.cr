# Port of egui_upstream/crates/egui/src/widgets/label.rs.
#
# A Label reserves its text size, paints the text, and returns a
# (non-clickable) Response — upstream `Sense::hover()`. Accepts a
# String or RichText; `wrap` lays the text out with greedy word-wrap
# against the available width (egui `Label::wrap`).

module Egui
  class Label
    include Widget

    getter rich : RichText
    getter? wrap : Bool

    def initialize(text : String, size : Float64? = nil, wrap : Bool = false)
      @rich = RichText.new(text)
      @rich.size(size) if size
      @wrap = wrap
    end

    def initialize(@rich : RichText, wrap : Bool = false)
      @wrap = wrap
    end

    def ui(ui : Ui) : Response
      style = ui.style
      runs = @rich.runs(style.font_size, style.visuals.text_color)
      max_width = @wrap ? ui.available_width : nil
      galley = ui.ctx.fonts.layout(runs, max_width)

      rect = ui.allocate_at_least(galley.size)
      id = ui.next_widget_id
      ui.painter.paint_galley(rect.min, galley, ui.ctx.fonts,
        style.visuals.text_color)

      ui.interact(rect, id, Sense.none)
    end
  end
end
