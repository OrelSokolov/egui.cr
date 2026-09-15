# Port of egui's SelectableLabel (upstream widgets/selectable_label.rs;
# in the vendored 0.36 tree it lives on as `Button::selectable`).
#
# A label-shaped toggle: when `selected`, it paints a selection fill
# under the text; hovered it hints with a faded selection. The classic
# building block for tab bars, list rows and segmented controls — and,
# via the block form `Ui#selectable`, for one-of-many choices.

module Egui
  class SelectableLabel
    include Widget

    def initialize(@selected : Bool, @text : String)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      text_size = ui.ctx.fonts.measure(@text, font_size)
      pad = style.spacing.button_padding
      height = {text_size.y + 2 * pad.y, style.spacing.interact_size.y}.max
      rect = ui.allocate_at_least(Vec2.new(text_size.x + 2 * pad.x, height))
      id = ui.next_widget_id
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      visuals = style.visuals
      if @selected
        fill = response.active? ? visuals.button_active : visuals.selection_fill
        ui.painter.rect(rect, 4.0, fill)
      elsif response.hovered?
        ui.painter.rect(rect, 4.0,
          visuals.fade_color(visuals.selection_fill, 0.4))
      end
      ui.painter.text(
        Pos2.new(rect.left + pad.x, rect.center.y), @text, font_size,
        visuals.text_color)

      response.paint_focus_ring
      response.mark_changed if response.clicked?
      response
    end
  end
end
