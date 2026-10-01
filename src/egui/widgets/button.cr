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
# `#icon(name)` draws a vector icon left of the text (a `Symbol` from
# `Icons::NAMES` or an `Svg`, e.g. `Icon.from_file(:lucide, :save)`).

module Egui
  class Button
    include Widget

    getter text : String

    @gradient : Tuple(Color32, Color32)?
    @icon : Symbol?
    @icon_svg : Svg?
    @image_texture : UInt64?
    @cursor : CursorIcon?

    def initialize(@text : String, id : String? = nil)
      @id_name = id
    end

    # egui `Button::min_size` — the button never shrinks below this
    # (text stays centered inside); the hook behind `Ui#big_button`.
    def min_size(size : Vec2) : self
      @min_size = size
      self
    end

    @min_size : Vec2?

    def style_class : String?
      "button"
    end

    # Every key #ui reads: the common button set plus the box-model
    # and 3D-bevel/shadow extras (see `default_theme.cr` for the
    # defaults). Declared here — the inspector renders what it's told.
    def style_properties : Array(StyleProp)
      StyleProps.buttonlike + [
        StyleProp.new("padding", :box),
        StyleProp.new("rounding", :number, fallback: 4.0),
        StyleProp.new("bevel_light", :color, states: true),
        StyleProp.new("bevel_dark", :color, states: true),
        StyleProp.new("shadow.color", :color, states: true),
        StyleProp.new("shadow.blur", :number),
        StyleProp.new("shadow.x", :number),
        StyleProp.new("shadow.y", :number),
        StyleProp.new("shadow.inset", :bool, states: true),
      ]
    end

    def inspector_label : String?
      @text
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

    # An SVG icon (e.g. `Icon.from_file(:lucide, :save, tint: fg)`),
    # drawn left of the text; takes precedence over the `Symbol`
    # vector icon, below a raster texture.
    def icon(svg : Svg) : self
      @icon_svg = svg
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
      id = resolve_id(ui)

      # Full cascade (theme → button class rules → per-widget `#style`
      # → inspector per-element override): see `default_theme.cr` for
      # the class defaults. Sizing uses the state-less style; the
      # state only picks colors, re-resolved after the interaction
      # verdict.
      class_vars = style_vars(ui, id, "button")
      style = effective_style(ui, id, class_vars)

      # Per-side padding box; falls back to Spacing#button_padding
      # (symmetric) when the class leaves it unset.
      bp = style.spacing.button_padding
      pad = class_vars.box?("padding") ||
            StyleBox.new(bp.y, bp.x, bp.y, bp.x)

      font_size = style.font_size
      fonts = ui.ctx.fonts_for(style.font_family)
      text_size = fonts.measure_cached(@text, font_size)
      # An icon-only button (empty label) still needs a glyph-height
      # box: `measure("")` is zero and would collapse the icon to
      # nothing. Fall back to the estimated line height.
      glyph_h = text_size.y > 0.0 ? text_size.y : font_size * Fonts::LINE_H_FACTOR
      # No text after the icon → no icon→text gap, so the glyph
      # centers in an icon-only button.
      icon_adv = @text.empty? ? 0.0 : style.spacing.icon_spacing
      size = Vec2.new(text_size.x + pad.horizontal,
        {text_size.y, glyph_h}.max + pad.vertical)
      # Size floor: the button's own `min_size:` when given, else the
      # global default (Ui::DEFAULT_WIDGET_SIZE) — content may grow the
      # button larger, but its size never collapses to zero.
      ms = @min_size || Vec2.new(Ui::DEFAULT_WIDGET_SIZE, Ui::DEFAULT_WIDGET_SIZE)
      size = Vec2.new({size.x, ms.x}.max, {size.y, ms.y}.max)
      if (tex = @image_texture) && !tex.zero?
        size += Vec2.new(glyph_h + icon_adv, 0.0)
      end
      if (svg = @icon_svg)
        size += Vec2.new(glyph_h + icon_adv, 0.0)
      elsif (name = @icon) && Icons::NAMES.includes?(name)
        size += Vec2.new(glyph_h + icon_adv, 0.0)
      end

      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, sense)
      if response.hovered? && (cursor = @cursor)
        ui.ctx.set_cursor_icon(cursor)
      end

      # CSS-like state resolution: ONE `background` key whose value for
      # the widget's live state comes from the cascade (element
      # override → inline `#style` → class base/:hover/:active rules →
      # theme slots) — see `Widget#background_color`. The stroke rides
      # the same state bag (a `button:hover { stroke }` rule applies
      # while hovered).
      state = response.active? ? "active" : response.hovered? ? "hover" : nil
      state_vars = style_vars(ui, id, "button", state)
      fill = background_color(ui, id, "button", state,
        response.hovered?, response.active?)
      stroke_color = state_vars.color?("stroke") ||
                     style.visuals.button_stroke
      # 3D bevel (Win95-style raised box): `bevel_light`/`bevel_dark`
      # keys, read from the SAME state bag as the fill — a
      # `button:active` rule swapping the two colors sinks the box.
      # The class `rounding` key replaces the hardcoded 4 px default.
      # The `shadow.*` keys (a CSS box-shadow, `StyleVars#shadow?`) draw
      # through the state overlay too: outset UNDER the fill, inset over
      # it — `button:active { shadow.inset }` is the bootstrap pressed
      # look.
      rounding = class_vars.f64("rounding", 4.0)
      shadow = state_vars.shadow?
      if shadow && !shadow.inset?
        ui.painter.box_shadow(rect, shadow.color, blur: shadow.blur,
          rounding: rounding, spread: shadow.spread, offset: shadow.offset)
      end
      bevel_light = state_vars.color?("bevel_light")
      bevel_dark = state_vars.color?("bevel_dark")
      if (grad = @gradient) && !response.active?
        ui.painter.rect(rect, rounding: rounding, fill: grad[0], fill2: grad[1],
          stroke_color: stroke_color, stroke_width: 1.0)
      elsif bevel_light && bevel_dark
        ui.painter.rect(rect, rounding: rounding, fill: fill)
        # Raised bevel: light on the top/left, dark on the bottom/right.
        ui.painter.line(rect.min + Vec2.new(0.0, 0.5),
          Pos2.new(rect.max.x, rect.min.y + 0.5), 1.0, bevel_light)
        ui.painter.line(rect.min + Vec2.new(0.5, 0.0),
          Pos2.new(rect.min.x + 0.5, rect.max.y), 1.0, bevel_light)
        ui.painter.line(Pos2.new(rect.max.x - 0.5, rect.min.y),
          Pos2.new(rect.max.x - 0.5, rect.max.y), 1.0, bevel_dark)
        ui.painter.line(Pos2.new(rect.min.x, rect.max.y - 0.5),
          Pos2.new(rect.max.x, rect.max.y - 0.5), 1.0, bevel_dark)
      else
        ui.painter.rect(rect, rounding: rounding, fill: fill,
          stroke_color: stroke_color, stroke_width: 1.0)
      end
      if shadow && shadow.inset?
        ui.painter.box_shadow(rect, shadow.color, blur: shadow.blur,
          rounding: rounding, spread: shadow.spread, offset: shadow.offset,
          inset: true)
      end

      # Content: optional icon + centered text. The icon→text gap
      # exists only between a real icon and a non-empty label — without
      # an icon there is nothing to gap, and a phantom advance would
      # push the text off-center (block_w would exceed the measured
      # text by icon_spacing, and the pen starts icon_spacing right of
      # block_left). Icon-only buttons likewise gap nothing.
      has_icon = ((tex = @image_texture) && !tex.zero?) ||
                 @icon_svg.is_a?(Svg) ||
                 ((name = @icon) && Icons::NAMES.includes?(name))
      icon_w = has_icon ? glyph_h : 0.0
      icon_adv = has_icon && !@text.empty? ? style.spacing.icon_spacing : 0.0
      # A host may clamp the rect below the natural size (the max-size
      # rule at a region edge — e.g. a "➕ Agent" button overflowing
      # the sidebar): truncate the label to what fits so the text
      # stays INSIDE the button instead of spilling past its fill.
      icon_room = icon_w + icon_adv
      max_text_w = {rect.width - pad.horizontal - icon_room, 0.0}.max
      label = @text.empty? ? @text : fonts.fit(@text, font_size, max_text_w)
      label_size = label.same?(@text) ? text_size :
                   fonts.measure_cached(label, font_size)
      block_w = icon_w + icon_adv + label_size.x
      # Center the block in the content box (rect minus padding); when
      # the cell is TIGHTER than the natural size (#add_sized
      # hard-clamps to the region's max rect — e.g. a fixed-size icon
      # cell at a panel edge), center in the whole rect instead so the
      # glyph stays inside instead of spilling past the right edge
      # into the clip.
      slack = (rect.width - pad.horizontal) - block_w
      block_left = if slack >= 0.0
        rect.left + pad.left + slack / 2.0
      else
        rect.left + (rect.width - block_w) / 2.0
      end
      if (tex = @image_texture) && !tex.zero?
        icon_box = Rect.from_min_size(
          Pos2.new(block_left, rect.center.y - glyph_h / 2.0),
          Vec2.new(glyph_h, glyph_h))
        ui.painter.image(icon_box, tex)
      elsif (svg = @icon_svg)
        icon_box = Rect.from_min_size(
          Pos2.new(block_left, rect.center.y - glyph_h / 2.0),
          Vec2.new(glyph_h, glyph_h))
        svg.paint(ui, icon_box)
      elsif (name = @icon) && Icons::NAMES.includes?(name)
        icon_box = Rect.from_min_size(
          Pos2.new(block_left, rect.center.y - glyph_h / 2.0),
          Vec2.new(glyph_h, glyph_h))
        Icons.draw(ui.painter, name, icon_box,
          style.visuals.text_color)
      end
      pos = Pos2.new(block_left + icon_w + icon_adv, rect.center.y)
      text_color = state_vars.color?("text_color") ||
                   style.visuals.text_color
      ui.painter.text(pos, label, font_size, text_color,
        family: style.font_family)

      response.paint_focus_ring
      response
    end
  end
end
