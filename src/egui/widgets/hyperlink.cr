# Port of egui_upstream/crates/egui/src/widgets/hyperlink.rs (lite).
#
# A colored, underlined, clickable label. The lite version paints a
# single-style run; full rich-text treatment lands with LayoutJob
# (phase 4). Opening the URL shells out to xdg-open on Linux.

module Egui
  class Hyperlink
    include Widget

    def initialize(@label : String, @url : String)
    end

    def ui(ui : Ui) : Response
      style = ui.style
      font_size = style.font_size
      text_size = ui.ctx.fonts.measure(@label, font_size)

      rect = ui.allocate_at_least(text_size)
      id = ui.next_widget_id
      response = ui.interact(rect, id, Sense.click)

      color = style.visuals.hyperlink_color
      color = color.mul_color(0.8) if response.active?
      ui.painter.text(rect.left_center, @label, font_size, color)

      # Underline a hairline below the text.
      underline_y = rect.bottom - 1.0
      ui.painter.line(
        Pos2.new(rect.left, underline_y),
        Pos2.new(rect.left + text_size.x, underline_y),
        1.0, color)

      Hyperlink.open_url(@url) if response.clicked?
      response
    end

    def self.open_url(url : String) : Nil
      Process.new("xdg-open", [url],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
    rescue File::Error | IO::Error
      # xdg-open missing or exec failed — nothing sensible to do headless.
    end
  end
end
