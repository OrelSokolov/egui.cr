# Port of egui_upstream/crates/egui/src/widgets/radio_button.rs.
#
# Like Checkbox but with a round icon: outer circle + inner dot when
# selected. Selection state lives in app state; a click reports through
# `Response#changed?`.

module Egui
  class RadioButton
    include Widget

    def initialize(@selected : Bool, @text : String)
    end

    # Styled through the `radio` class: `ring_fill`, `ring_stroke`,
    # `dot_fill` keys (unset keys keep the classic look — a hollow 1px
    # ring + a text-colored dot; a platform theme fills the circle,
    # e.g. macOS paints a #D5D5D5 disc, selected a blue one with a
    # white dot).
    def style_class : String?
      "radio"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + StyleProps.sizable + [
        StyleProp.new("ring_fill", :color, states: true),
        StyleProp.new("ring_stroke", :color),
        StyleProp.new("dot_fill", :color, states: true),
      ]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      sp = style.spacing
      font_size = style.font_size
      text_size = ui.ctx.fonts_for(style.font_family).measure(@text, font_size)

      icon = sp.icon_width
      height = {icon, text_size.y}.max
      total_width = icon + sp.icon_spacing + text_size.x
      id = ui.next_widget_id
      size = styled_size(Vec2.new(total_width, height),
        style_vars(ui, id), ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      visuals = style.visuals
      class_vars = style_vars(ui, id)
      selected_vars = style_vars(ui, id, "selected")
      center = Pos2.new(rect.left + icon / 2.0, rect.center.y)

      # The circle: a filled disc when a `ring_fill` is styled (the
      # macOS look), otherwise the classic hollow ring — upstream draws
      # the idle ring with `bg_stroke`, NOT a fill (fills track the
      # panel background in light themes, which made the unselected
      # ring invisible there — see checkbox's box_stroke for the same
      # arrangement). An explicit `ring_stroke` rides a filled disc
      # too; without one the disc stays flat (native has no rim).
      state = response.active? ? "active" : response.hovered? ? "hover" : nil
      fill = @selected ? selected_vars.color?("ring_fill") : nil
      fill ||= style_vars(ui, id, state).color?("ring_fill")
      if fill
        ui.painter.circle_filled(center, icon / 2.0, fill)
      end
      if (stroke = class_vars.color?("ring_stroke")) || !fill
        ui.painter.circle_stroke(center, icon / 2.0,
          stroke || visuals.button_stroke, 1.0)
      end

      if @selected
        # `radio:selected` rule layer (dot_fill) — a platform theme
        # paints the dot white over the blue disc (macOS) instead of
        # the text color.
        ui.painter.circle_filled(center, sp.icon_width_inner / 2.0,
          selected_vars.color("dot_fill", visuals.text_color))
      end

      # A clamped host squeezes the rect below the natural size:
      # truncate to the room left of the icon's trailing edge (see
      # Fonts#fit).
      label = ui.ctx.fonts_for(style.font_family)
        .fit(@text, font_size, {rect.width - icon - sp.icon_spacing, 0.0}.max)
      text_pos = Pos2.new(rect.left + icon + sp.icon_spacing, rect.center.y)
      ui.painter.text(text_pos, label, font_size, visuals.text_color,
        family: style.font_family)

      response.paint_focus_ring(9.0)
      response.mark_changed if response.clicked? && !@selected
      response
    end
  end
end
