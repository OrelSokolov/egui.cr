# Port of egui_upstream/crates/egui/src/widgets/button.rs.
#
# Upstream `Button::ui` in five moves, kept in the same order here:
#   1. sense = Sense::click()
#   2. size = text size + 2 * button_padding
#   3. (rect, response) = ui.allocate_at_least(size)
#   4. re-interact: ui.interact(rect, id, sense)
#   5. paint: bg rect (state-colored) + centered text; return response
#
# egui.cr extras: `#gradient(c1, c2)` paints a vertical gradient fill,
# `#icon(name)` draws a vector icon left of the text.

module Egui
  class Button
    include Widget

    getter text : String

    @gradient : Tuple(Color32, Color32)?
    @icon : Symbol?
    @image_texture : UInt64?
    @cursor : CursorIcon?

    def initialize(@text : String)
    end

    # CSS `cursor` style for this button — the icon the mouse shows
    # while hovering it (default: `style.visuals.interact_cursor`).
    def cursor(icon : CursorIcon) : self
      @cursor = icon
      self
    end

    # Vertical gradient fill (top c1 → bottom c2); overrides the plain
    # state fill.
    def gradient(c1 : Color32, c2 : Color32) : self
      @gradient = {c1, c2}
      self
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
      pad = ui.style.spacing.button_padding

      text_size = ui.ctx.fonts.measure(@text, ui.style.font_size)
      size = text_size + pad * 2.0
      if (name = @icon) && Icons::NAMES.includes?(name)
        size += Vec2.new(text_size.y + ui.style.spacing.icon_spacing, 0.0)
      end
      if (tex = @image_texture) && !tex.zero?
        size += Vec2.new(text_size.y + ui.style.spacing.icon_spacing, 0.0)
      end

      rect = ui.allocate_at_least(size)
      id = ui.next_widget_id
      response = ui.interact(rect, id, sense)
      if response.hovered? && (cursor = @cursor)
        ui.ctx.set_cursor_icon(cursor)
      end

      if (grad = @gradient) && !response.active?
        ui.painter.rect(rect, rounding: 4.0, fill: grad[0], fill2: grad[1],
          stroke_color: ui.style.visuals.button_stroke, stroke_width: 1.0)
      else
        fill = ui.style.visuals.button_fill(response.hovered?, response.active?)
        ui.painter.rect(rect, rounding: 4.0, fill: fill,
          stroke_color: ui.style.visuals.button_stroke, stroke_width: 1.0)
      end

      # Content: optional icon + centered text.
      content_left = rect.left + pad.x
      content_w = rect.width - 2 * pad.x
      if (tex = @image_texture) && !tex.zero?
        icon_box = Rect.from_min_size(
          Pos2.new(content_left, rect.center.y - text_size.y / 2.0),
          Vec2.new(text_size.y, text_size.y))
        ui.painter.image(icon_box, tex)
        content_left += text_size.y + ui.style.spacing.icon_spacing
        content_w -= text_size.y + ui.style.spacing.icon_spacing
      end
      if (name = @icon) && Icons::NAMES.includes?(name)
        icon_box = Rect.from_min_size(
          Pos2.new(content_left, rect.center.y - text_size.y / 2.0),
          Vec2.new(text_size.y, text_size.y))
        Icons.draw(ui.painter, name, icon_box,
          ui.style.visuals.text_color)
        content_left += text_size.y + ui.style.spacing.icon_spacing
        content_w -= text_size.y + ui.style.spacing.icon_spacing
      end
      pos = Pos2.new(content_left + (content_w - text_size.x).clamp(0.0, Float64::MAX) / 2.0,
        rect.center.y)
      ui.painter.text(pos, @text, ui.style.font_size,
        ui.style.visuals.text_color)

      response.paint_focus_ring
      response
    end
  end
end
