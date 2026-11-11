# Port of egui_upstream/crates/egui/src/widgets/radio_button.rs.
#
# Like Checkbox but with a round icon: outer ring + inner dot when
# selected. Selection state lives in app state; a click reports through
# `Response#changed?`.

module Egui
  class RadioButton
    include Widget

    def initialize(@selected : Bool, @text : String)
    end

    # Styled through the `radio` class, like Checkbox: the textlike
    # keys (`text_color` for the label, `font_*`) plus `dot_fill` (the
    # selected dot; unset keeps the text color — see the `radio:selected`
    # read below).
    def style_class : String?
      "radio"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + StyleProps.sizable +
        [StyleProp.new("dot_fill", :color)]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      id = ui.next_widget_id
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)
      sp = style.spacing
      font_size = style.font_size
      fonts = ui.ctx.fonts_for(style.font_family)
      text_size = fonts.measure(@text, font_size)

      icon = sp.icon_width
      height = {icon, text_size.y}.max
      total_width = icon + sp.icon_spacing + text_size.x
      size = styled_size(Vec2.new(total_width, height),
        class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      visuals = style.visuals
      center = Pos2.new(rect.left + icon / 2.0, rect.center.y)
      # Upstream draws the idle ring with `bg_stroke`, NOT the button
      # fill — fills track the panel background in light themes, which
      # made the unselected ring invisible there (see checkbox's
      # box_stroke for the same arrangement).
      ui.painter.circle_stroke(center, icon / 2.0,
        visuals.button_stroke, 1.0)

      if @selected
        # `radio:selected` rule layer (dot_fill) — a platform theme
        # paints the dot in the accent color (macOS) instead of text.
        ui.painter.circle_filled(center, sp.icon_width_inner / 2.0,
          style_vars(ui, id, "selected").color("dot_fill",
            visuals.text_color))
      end

      # A clamped host squeezes the rect below the natural size:
      # truncate to the room left of the icon's trailing edge (see
      # Fonts#fit).
      label = fonts.fit(@text, font_size, {rect.width - icon - sp.icon_spacing, 0.0}.max)
      text_pos = Pos2.new(rect.left + icon + sp.icon_spacing, rect.center.y)
      ui.painter.text(text_pos, label, font_size, visuals.text_color,
        family: style.font_family)

      response.paint_focus_ring(9.0)
      response.mark_changed if response.clicked? && !@selected
      response
    end
  end
end
