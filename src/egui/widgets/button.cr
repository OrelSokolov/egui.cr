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
# `Icons::NAMES` or an `Svg`, e.g. `Icon.from_file(:lucide, :save)`);
# `#vertical` stacks the icon ABOVE the text (both centered — the
# square-tile idiom of home-screen mode buttons), with `#icon_size`
# scaling the icon independently of the label's line height.

module Egui
  class Button
    include Widget

    getter text : String

    @gradient : Tuple(Color32, Color32)?
    @icon : Symbol?
    @icon_svg : Svg?
    @image_texture : UInt64?
    @cursor : CursorIcon?
    @vertical = false
    @icon_trailing = false
    @icon_size : Float64?

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
    @rounding : Float64?

    # Corner rounding override (points); nil keeps the class default
    # (4 px). `height / 2` turns the button into a pill/oval.
    def rounding(r : Float64) : self
      @rounding = r
      self
    end

    def style_class : String?
      "button"
    end

    # Every key #ui reads: the common button set plus the box-model
    # and 3D-bevel/shadow extras (see `default_theme.cr` for the
    # defaults). Declared here — the inspector renders what it's told.
    def style_properties : Array(StyleProp)
      StyleProps.buttonlike + StyleProps.sizable + [
        StyleProp.new("padding", :box),
        StyleProp.new("rounding", :number, fallback: 4.0, min: 0.0),
        StyleProp.new("bevel_light", :color, states: true),
        StyleProp.new("bevel_dark", :color, states: true),
        StyleProp.new("shadow.color", :color, states: true),
        StyleProp.new("shadow.blur", :number, min: 0.0),
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

    # Vertical layout: the icon sits above the label (both centered in
    # the button) — the square-tile idiom; in this mode the icon takes
    # its size from `#icon_size` when given, else the label's line
    # height (the horizontal default).
    def vertical(flag : Bool = true) : self
      @vertical = flag
      self
    end

    # Explicit icon size in points; without it the icon is a
    # glyph-height square (the text's line height).
    def icon_size(s : Float64) : self
      @icon_size = s
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

    # An SVG icon drawn RIGHT of the text — the trailing-arrow idiom
    # ("Next ›"). Overrides `#icon`'s leading icon.
    def icon_trailing(svg : Svg) : self
      @icon_svg = svg
      @icon_trailing = true
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
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)

      # Per-side padding box; falls back to Spacing#button_padding
      # (symmetric) when the class leaves it unset.
      bp = style.spacing.button_padding
      pad = class_vars.box?("padding") ||
            StyleBox.new(bp.y, bp.x, bp.y, bp.x)

      font_size = style.font_size
      # Weight goes through the real axis (a cut face when the family
      # has one) — measure and draw share the resolved stack.
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      text_size = fonts.measure_cached(@text, font_size)
      # An icon-only button (empty label) still needs a glyph-height
      # box: `measure("")` is zero and would collapse the icon to
      # nothing. Fall back to the estimated line height.
      glyph_h = text_size.y > 0.0 ? text_size.y : font_size * Fonts::LINE_H_FACTOR
      # Icon presence up front: the natural size (both layouts) and the
      # content block below share it. The icon is a square of the
      # explicit `#icon_size`, else the label's line height.
      has_icon = ((tex0 = @image_texture) && !tex0.zero?) ||
                 @icon_svg.is_a?(Svg) ||
                 ((name0 = @icon) && Icons::NAMES.includes?(name0))
      icon_h = has_icon ? (@icon_size || glyph_h) : 0.0
      # The icon→text gap exists only between a real icon and a
      # non-empty label — without an icon there is nothing to gap, and
      # a phantom advance would push the text off-center.
      gap = has_icon && !@text.empty? ? style.spacing.icon_spacing : 0.0
      if @vertical
        # Square tile: the icon stacks ABOVE the label, so the icon
        # grows the HEIGHT and the width is the wider of the two.
        size = Vec2.new({text_size.x, icon_h}.max + pad.horizontal,
          icon_h + gap + {text_size.y, glyph_h}.max + pad.vertical)
      else
        size = Vec2.new(text_size.x + icon_h + gap + pad.horizontal,
          {text_size.y, glyph_h}.max + pad.vertical)
      end
      # Size floor: the button's own `min_size:` when given, else the
      # global default (Ui::DEFAULT_WIDGET_SIZE) — content may grow the
      # button larger, but its size never collapses to zero.
      ms = @min_size || Vec2.new(Ui::DEFAULT_WIDGET_SIZE, Ui::DEFAULT_WIDGET_SIZE)
      size = Vec2.new({size.x, ms.x}.max, {size.y, ms.y}.max)

      # Responsive size keys (`width`/`min_width`/`max_width`… —
      # points, `%` of the containing Ui, vw/vh/vmin/vmax, rem) are
      # the last word on each axis, after content and min_size floor.
      # `transition.width` animates the declared size between targets.
      size = styled_size(size, class_vars, ui, id)

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
      state_vars = style_vars(ui, id, state)
      fill = background_color(ui, id, state,
        response.hovered?, response.active?)
      stroke_color = state_vars.color?("stroke") ||
                     style.visuals.button_stroke
      stroke_color = transition_color("stroke", stroke_color,
        state_vars, ui, id)
      # 3D bevel (Win95-style raised box): `bevel_light`/`bevel_dark`
      # keys, read from the SAME state bag as the fill — a
      # `button:active` rule swapping the two colors sinks the box.
      # The class `rounding` key replaces the hardcoded 4 px default.
      # The `shadow.*` keys (a CSS box-shadow, `StyleVars#shadow?`) draw
      # through the state overlay too: outset UNDER the fill, inset over
      # it — `button:active { shadow.inset }` is the bootstrap pressed
      # look.
      rounding = @rounding || class_vars.f64("rounding", 4.0)
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

      # Content: optional icon + centered text. Horizontal layout packs
      # the block [icon | gap | label] left-to-right and centers it in
      # the content box; `#vertical` stacks it [icon / gap / label]
      # top-to-bottom instead. When the cell is TIGHTER than the
      # natural size (#add_sized hard-clamps to the region's max rect
      # — e.g. a fixed-size tile at a panel edge), the block centers in
      # the whole rect so the glyph stays inside instead of spilling
      # past the edge into the clip. A host clamp may also force the
      # label to truncate (`fonts.fit`) to what fits.
      max_text_w = if @vertical
        {rect.width - pad.horizontal, 0.0}.max
      else
        {rect.width - pad.horizontal - icon_h - gap, 0.0}.max
      end
      label = @text.empty? ? @text : fonts.fit(@text, font_size, max_text_w)
      label_size = label.same?(@text) ? text_size :
                   fonts.measure_cached(label, font_size)

      icon_box : Rect? = nil
      pos : Pos2
      if @vertical
        block_h = icon_h + gap + label_size.y
        slack = (rect.height - pad.vertical) - block_h
        block_top = slack >= 0.0 ? rect.top + pad.top + slack / 2.0
                                 : rect.top + (rect.height - block_h) / 2.0
        cx = rect.center.x
        if has_icon
          icon_box = Rect.from_min_size(
            Pos2.new(cx - icon_h / 2.0, block_top),
            Vec2.new(icon_h, icon_h))
        end
        pos = Pos2.new(cx - label_size.x / 2.0,
          block_top + icon_h + gap + label_size.y / 2.0)
      else
        block_w = icon_h + gap + label_size.x
        slack = (rect.width - pad.horizontal) - block_w
        block_left = if slack >= 0.0
          rect.left + pad.left + slack / 2.0
        else
          rect.left + (rect.width - block_w) / 2.0
        end
        if has_icon && @icon_trailing
          # Trailing icon: label first, the glyph after it.
          icon_box = Rect.from_min_size(
            Pos2.new(block_left + label_size.x + gap,
              rect.center.y - icon_h / 2.0),
            Vec2.new(icon_h, icon_h))
          pos = Pos2.new(block_left, rect.center.y)
        else
          if has_icon
            icon_box = Rect.from_min_size(
              Pos2.new(block_left, rect.center.y - icon_h / 2.0),
              Vec2.new(icon_h, icon_h))
          end
          pos = Pos2.new(block_left + icon_h + gap, rect.center.y)
        end
      end
      if (b = icon_box) && (tex = @image_texture) && !tex.zero?
        ui.painter.image(b, tex)
      elsif (b = icon_box) && (svg = @icon_svg)
        svg.paint(ui, b)
      elsif (b = icon_box) && (name = @icon) && Icons::NAMES.includes?(name)
        Icons.draw(ui.painter, name, b, style.visuals.text_color)
      end
      text_color = state_vars.color?("text_color") ||
                   style.visuals.text_color
      ui.painter.text(pos, label, font_size, text_color,
        family: face_family, bold: face_bold)

      response.paint_focus_ring
      response
    end
  end
end
