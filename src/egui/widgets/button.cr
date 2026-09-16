# Port of egui_upstream/crates/egui/src/widgets/button.rs.
#
# Upstream `Button::ui` in five moves, kept in the same order here:
#   1. sense = Sense::click()
#   2. size = text size + 2 * button_padding
#   3. (rect, response) = ui.allocate_at_least(size)
#   4. re-interact: ui.interact(rect, id, sense)
#   5. paint: bg rect (state-colored) + centered text; return response
#
# egui.cr extras: `#css(name)` styles the button under the element
# class "button.<name>" (a CSS class selector — inherits every
# "button" rule through the cascade), `#icon(name)` draws a vector
# icon left of the text. Gradient fills come from the style system
# (`background_gradient` — see `Visuals#background_gradient`).

module Egui
  class Button
    include Widget

    getter text : String

    @extra_class : String?
    @icon : Symbol?
    @image_texture : UInt64?
    @cursor : CursorIcon?

    def initialize(@text : String)
    end

    def style_class : String?
      @extra_class ? "button.#{@extra_class}" : "button"
    end

    # Extra element class (CSS `class="button success"`): the button
    # resolves its styles under "button.<name>", so "button.<name>*"
    # rules add to / override the base "button" rules.
    def css(name : String) : self
      @extra_class = name
      self
    end

    # CSS `cursor` style for this button — the icon the mouse shows
    # while hovering it (default: `style.visuals.interact_cursor`).
    def cursor(icon : CursorIcon) : self
      @cursor = icon
      self
    end

    # Vertical gradient fill (top c1 → bottom c2) — thin wrapper over
    # the per-widget style override; prefer the stylesheet
    # ("button.<name>" + `background_gradient`).
    def gradient(c1 : Color32, c2 : Color32) : self
      style { |s| s.background_gradient = Gradient.new(c1, c2) }
    end

    # A vector icon from `Icons::NAMES`, drawn left of the text.
    def icon(name : Symbol) : self
      @icon = name
      self
    end

    # A raster icon: texture drawn left of the text (phase 6; takes
    # precedence over the vector icon).
    def image_texture(texture_id : UInt64) : self
      @image_texture = texture_id
      self
    end

    def ui(ui : Ui) : Response
      sense = Sense.click | Sense::Focusable

      # Full cascade (theme → button class → :hover/:active overlay →
      # per-widget `#style`): see `default_theme.cr` for the class
      # defaults. Sizing uses the state-less style; the state only
      # picks colors, re-resolved after the interaction verdict.
      sheet = ui.ctx.stylesheet
      class_vars = sheet.resolve(style_class.not_nil!)
      style = effective_style(ui, class_vars)

      # Per-side padding box; falls back to Spacing#button_padding
      # (symmetric) when the class leaves it unset.
      bp = style.spacing.button_padding
      pad = class_vars.box?("padding") ||
            StyleBox.new(bp.y, bp.x, bp.y, bp.x)

      font_size = style.font_size
      text_size = ui.ctx.fonts.measure(@text, font_size)
      size = Vec2.new(text_size.x + pad.horizontal,
        text_size.y + pad.vertical)
      # Upstream Button::ui: never smaller than the style's minimum
      # interactive size.
      size = Vec2.new({size.x, style.spacing.interact_size.x}.max,
        {size.y, style.spacing.interact_size.y}.max)
      if (name = @icon) && Icons::NAMES.includes?(name)
        size += Vec2.new(text_size.y + style.spacing.icon_spacing, 0.0)
      end
      if (tex = @image_texture) && !tex.zero?
        size += Vec2.new(text_size.y + style.spacing.icon_spacing, 0.0)
      end

      rect = ui.allocate_at_least(size)
      id = ui.next_widget_id
      response = ui.interact(rect, id, sense)
      if response.hovered? && (cursor = @cursor)
        ui.ctx.set_cursor_icon(cursor)
      end

      # The state overlay slots UNDER any `#style` overrides, so an
      # inline fill still wins over `button:hover`.
      state = response.active? ? "active" : response.hovered? ? "hover" : nil
      paint_style = state ? effective_style(ui, class_vars, state) : style
      fill = paint_style.visuals.button_fill(response.hovered?, response.active?)
      if (grad = paint_style.visuals.background_gradient)
        # Bootstrap-2 interaction, computed: hover shades the gradient
        # ~15%, active ~30% — UNLESS a state rule ("button.x:hover")
        # pins its own `background_gradient`, which is then used as-is.
        pinned = state && sheet.state_vars(style_class.not_nil!, state)
                                 .try(&.gradient?("background_gradient"))
        factor = pinned ? 1.0 :
          response.active? ? 0.70 : response.hovered? ? 0.85 : 1.0
        shaded = grad.mul(factor)
        ui.painter.rect(rect, rounding: 4.0, fill: shaded.top,
          fill2: shaded.bottom,
          stroke_color: paint_style.visuals.border_color, stroke_width: 1.0)
      else
        ui.painter.rect(rect, rounding: 4.0, fill: fill,
          stroke_color: paint_style.visuals.border_color, stroke_width: 1.0)
      end

      # Content: optional icon + centered text.
      content_left = rect.left + pad.left
      content_w = rect.width - pad.horizontal
      if (tex = @image_texture) && !tex.zero?
        icon_box = Rect.from_min_size(
          Pos2.new(content_left, rect.center.y - text_size.y / 2.0),
          Vec2.new(text_size.y, text_size.y))
        ui.painter.image(icon_box, tex)
        content_left += text_size.y + style.spacing.icon_spacing
        content_w -= text_size.y + style.spacing.icon_spacing
      end
      if (name = @icon) && Icons::NAMES.includes?(name)
        icon_box = Rect.from_min_size(
          Pos2.new(content_left, rect.center.y - text_size.y / 2.0),
          Vec2.new(text_size.y, text_size.y))
        Icons.draw(ui.painter, name, icon_box,
          style.visuals.text_color)
        content_left += text_size.y + style.spacing.icon_spacing
        content_w -= text_size.y + style.spacing.icon_spacing
      end
      pos = Pos2.new(content_left + (content_w - text_size.x).clamp(0.0, Float64::MAX) / 2.0,
        rect.center.y)
      ui.painter.text(pos, @text, font_size, paint_style.visuals.text_color)

      response.paint_focus_ring
      response
    end
  end
end
