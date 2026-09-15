# Port of egui_upstream/crates/egui/src/containers/combo_box.rs.
#
# A closed set of String options: a button showing the current
# selection that opens the shared popup system (Foreground layer,
# closes on outside click) with one item per option.

module Egui
  class ComboBox
    def initialize(@id : String, @selected : String,
                   @options : Array(String), @width : Float64 = 160.0)
    end

    # `on_select` fires with the picked option; returns whether a new
    # option got picked this frame.
    def show(ui : Ui, &on_select : String ->) : Bool
      style = ui.style
      font_size = style.font_size
      label = "#{@selected} ▾"
      text_size = ui.ctx.fonts.measure(label, font_size)

      size = Vec2.new({@width, text_size.x + style.spacing.button_padding.x * 2}.max,
        {text_size.y, style.spacing.interact_size.y}.max)
      rect = ui.allocate_at_least(size)
      id = ui.next_widget_id
      response = ui.interact(rect, id, Sense.click)

      visuals = style.visuals
      ui.painter.rect(rect, 3.0,
        visuals.button_fill(response.hovered?, response.active?),
        visuals.button_stroke, 1.0)
      pad_x = (rect.width - text_size.x) / 2.0
      ui.painter.text(Pos2.new(rect.left + pad_x, rect.center.y), label,
        font_size, visuals.text_color)

      # Toggle: a click while open closes (like MenuButton); without
      # this the re-open would also shield the popup from the
      # click-elsewhere close in Memory#end_frame.
      if response.clicked?
        if ui.ctx.popup_open?(@id)
          ui.ctx.close_popup(@id)
        else
          ui.ctx.open_popup(@id)
        end
      end

      picked = false
      ui.ctx.popup(@id, Pos2.new(rect.left, rect.bottom),
        width: rect.width, min_width: rect.width) do |pop|
        @options.each do |option|
          item_size = ui.ctx.fonts.measure(option, font_size) +
            style.spacing.button_padding * 2.0
          item_rect = pop.allocate_at_least(
            Vec2.new({rect.width - pop.style.spacing.window_padding.x * 2,
                      item_size.x}.max, item_size.y))
          item_id = pop.next_widget_id
          item_resp = pop.interact(item_rect, item_id, Sense.click)
          if option == @selected
            pop.painter.rect(item_rect, 3.0, visuals.button_hovered)
          elsif item_resp.hovered?
            pop.painter.rect(item_rect, 3.0, visuals.button_weak)
          end
          pop.painter.text(item_rect.left_center, option, font_size,
            visuals.text_color)
          if item_resp.clicked?
            on_select.call(option)
            ui.ctx.close_popup(@id)
            picked = true
          end
        end
      end
      picked
    end
  end
end
