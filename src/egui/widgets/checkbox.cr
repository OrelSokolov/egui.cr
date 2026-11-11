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
      StyleProps.textlike + StyleProps.sizable + [
        StyleProp.new("box_fill", :color, states: true),
        StyleProp.new("box_stroke", :color),
        StyleProp.new("check_color", :color),
        StyleProp.new("check_width", :number, fallback: 2.0, min: 0.5),
        StyleProp.new("rounding", :number, fallback: 3.0),
      ]
    end

    def inspector_label : String?
      @text
    end

    # Retained paint (see paint_cache.cr): content = text + checked
    # flag; the checked branch reads its own "checked" state bag, so
    # that bag's identity is a key input too. Hover/active enter via
    # the state bag chosen from Memory#interaction_state.
    def paint_cache_key(ui : Ui)
      id = cache_id(ui)
      state = ui.ctx.memory.interaction_state(id)
      base = style_vars(ui, id)
      stated = style_vars(ui, id, state)
      checked = style_vars(ui, id, "checked")
      {"checkbox", @text, @checked, ui.available_width,
       base.object_id, stated.object_id, checked.object_id,
       ui.style.object_id, @style_override.try(&.hash)}
    end

    # #ui's non-paint side effects: the changed flag rides the
    # response the caller reads.
    def cache_replay(ui : Ui, response : Response) : Nil
      response.mark_changed if response.clicked?
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      # Class rules through the full cascade: the textlike keys
      # (`text_color` for the label, `font_*`) apply over the theme
      # Style; the box keys below are read from the same bag raw.
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)
      sp = style.spacing
      font_size = style.font_size
      visuals = style.visuals
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      text_size = fonts.measure(@text, font_size)

      icon = sp.icon_width
      height = {icon, text_size.y}.max
      total_width = icon + sp.icon_spacing + text_size.x
      size = styled_size(Vec2.new(total_width, height),
        class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      icon_rect = Rect.from_min_size(
        Pos2.new(rect.left, rect.center.y - icon / 2.0),
        Vec2.new(icon, icon))
      # `box_fill` is state-scoped (states: true) — read from the
      # state-aware bag so a `checkbox:hover { box_fill }` rule applies;
      # the fallback is the theme's state slots.
      state = response.active? ? "active" : response.hovered? ? "hover" : nil
      state_vars = style_vars(ui, id, state)
      if @checked
        # A two-segment checkmark (upstream draws a font glyph; we use
        # the phase-0 line primitive). A `checkbox:checked` rule layer
        # (box_fill/check_color) lets a platform theme repaint the
        # checked box — macOS fills it with the accent color.
        checked_vars = style_vars(ui, id, "checked")
        box_fill = checked_vars.color?("box_fill") ||
                   state_vars.color("box_fill",
                     visuals.button_fill(response.hovered?, response.active?))
        ui.painter.rect(icon_rect,
          class_vars.rounding_px("rounding", icon_rect, 3.0),
          box_fill,
          class_vars.color("box_stroke", visuals.button_stroke), 1.0,
          corners: class_vars.rounding_corners?("rounding", icon_rect))
        c = icon_rect.min
        w = icon_rect.width
        h = icon_rect.height
        corner = Pos2.new(c.x + 0.26 * w, c.y + 0.52 * h)
        elbow = Pos2.new(c.x + 0.45 * w, c.y + 0.72 * h)
        tip = Pos2.new(c.x + 0.78 * w, c.y + 0.26 * h)
        check_color = checked_vars.color?("check_color") ||
                      class_vars.color("check_color", visuals.text_color)
        check_w = class_vars.f64("check_width", 2.0)
        ui.painter.line(corner, elbow, check_w, check_color)
        ui.painter.line(elbow, tip, check_w, check_color)
      else
        ui.painter.rect(icon_rect,
          class_vars.rounding_px("rounding", icon_rect, 3.0),
          state_vars.color("box_fill",
            visuals.button_fill(response.hovered?, response.active?)),
          class_vars.color("box_stroke", visuals.button_stroke), 1.0,
          corners: class_vars.rounding_corners?("rounding", icon_rect))
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
