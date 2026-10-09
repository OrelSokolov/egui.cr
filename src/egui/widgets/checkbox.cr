# Port of egui_upstream/crates/egui/src/widgets/checkbox.rs.
#
# A toggle backed by app state: the widget reads `checked`, paints icon
# + label, and reports the toggle through `Response#changed?` (the Ui#
# checkbox block form hands the new value back).

module Egui
  class Checkbox
    include Widget

    def initialize(@checked : Bool, @text : String, id : String? = nil)
      @id_name = id
    end

    # Styled through the `checkbox` class: `box_fill`, `box_stroke`,
    # `rounding`, `check_color` keys (unset keys keep the Visuals
    # defaults — the classic look registers nothing, a Win95 preset
    # paints a white sunken box with a black check).
    def style_class : String?
      "checkbox"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + [
        StyleProp.new("box_fill", :color, states: true),
        StyleProp.new("box_stroke", :color),
        StyleProp.new("check_color", :color),
        StyleProp.new("rounding", :number, fallback: 3.0),
      ]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      sp = style.spacing
      font_size = style.font_size
      visuals = style.visuals
      class_vars = style_vars(ui, id)
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      text_size = fonts.measure(@text, font_size)

      icon = sp.icon_width
      height = {icon, text_size.y}.max
      total_width = icon + sp.icon_spacing + text_size.x
      rect = ui.allocate_at_least(Vec2.new(total_width, height))
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      icon_rect = Rect.from_min_size(
        Pos2.new(rect.left, rect.center.y - icon / 2.0),
        Vec2.new(icon, icon))
      # `box_fill` is state-scoped (states: true) — read from the
      # state-aware bag so a `checkbox:hover { box_fill }` rule applies;
      # the fallback is the theme's state slots.
      state = response.active? ? "active" : response.hovered? ? "hover" : nil
      state_vars = style_vars(ui, id, state)
      ui.painter.rect(icon_rect,
        class_vars.f64("rounding", 3.0),
        state_vars.color("box_fill",
          visuals.button_fill(response.hovered?, response.active?)),
        class_vars.color("box_stroke", visuals.button_stroke), 1.0)

      if @checked
        # A two-segment checkmark (upstream draws a font glyph; we use
        # the phase-0 line primitive).
        c = icon_rect.min
        w = icon_rect.width
        h = icon_rect.height
        corner = Pos2.new(c.x + 0.26 * w, c.y + 0.52 * h)
        elbow = Pos2.new(c.x + 0.45 * w, c.y + 0.72 * h)
        tip = Pos2.new(c.x + 0.78 * w, c.y + 0.26 * h)
        check_color = class_vars.color("check_color", visuals.text_color)
        ui.painter.line(corner, elbow, 2.0, check_color)
        ui.painter.line(elbow, tip, 2.0, check_color)
      end

      # A clamped host squeezes the rect below the natural size:
      # truncate to the room left of the icon's trailing edge (see
      # Fonts#fit).
      label = fonts.fit(@text, font_size,
        {rect.width - icon - sp.icon_spacing, 0.0}.max)
      text_pos = Pos2.new(icon_rect.right + sp.icon_spacing, rect.center.y)
      ui.painter.text(text_pos, label, font_size, visuals.text_color,
        family: face_family, bold: face_bold)

      response.paint_focus_ring(9.0)
      response.mark_changed if response.clicked?
      response
    end
  end
end
