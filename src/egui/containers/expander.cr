# Expander — a Windows 11 style accordion (no direct upstream
# counterpart; the closest kin is `CollapsingHeader`, which this
# subsumes with a Win11 look): a full-width header row with the label
# on the left and a chevron on the right that flips 180° (points down
# closed, up open), and a content area that reveals below with an
# animated slide. The block gets a normal `Ui` — any widgets can live
# inside (the "canvas" is the same `child_ui` mechanism Sidebar and
# TreeView use).
#
#   ui.expander("Bluetooth & devices", icon: :bluetooth) do |body|
#     body.label("2 paired devices")
#     body.button("Add device")
#   end
#
# State is system state, like CollapsingHeader: the open flag AND the
# measured content height live in `Memory#data` keyed by the header's
# id — they survive frames where the expander (or its whole page) is
# not created, and the app never holds them. The height drives the
# reveal: content is laid out unbounded and clipped to `height ×
# open_amount`, so following widgets slide with the animation instead
# of popping (interaction is clip-limited too — a half-revealed row
# can't be clicked where it's hidden).
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   expander.header  — padding, rounding, font_size, font_family,
#                      text_color, background + :hover/:active
#                      overlays (background, text_color)
#   expander.content — padding, rounding, background (the reveal
#                      area's box — kept visually distinct from the
#                      header fill by the default theme)
# The theme presets ship the defaults (`default_theme.cr`).

module Egui
  class Expander
    # Element classes for `StyleSheet` tweaks from app code:
    #   ctx.stylesheet.rule(Expander::HEADER_CLASS, …)
    # The header/content reads and the content block run inside the
    # "expander" style scope (`Ui#with_style_scope` in #show), so
    # nested real widgets chain onto "expander.*" too.
    ROOT_CLASS    = "expander"
    HEADER_CLASS  = "expander.header"
    CONTENT_CLASS = "expander.content"

    # `icon` is an optional `Icons` glyph drawn before the label —
    # the Win11 settings look (`icon: :bluetooth` next to "Bluetooth
    # & devices").
    def initialize(@text : String, @default_open : Bool = false,
                   @icon : Symbol? = nil)
    end

    def show(ui : Ui, &block : Ui ->) : Response
      # Style scope: header/content keys stay "expander.*" and any
      # widget added inside the reveal chains onto them — see
      # `Ui#with_style_scope`.
      ui.with_style_scope(ROOT_CLASS) { render(ui, &block) }
    end

    private def render(ui : Ui, &block : Ui ->) : Response
      ctx = ui.ctx
      memory = ctx.memory
      sheet = ctx.stylesheet
      style = ui.style
      visuals = style.visuals

      # Ids: the header row's id doubles as the open-flag key (its
      # #interact call keeps it alive through end-frame pruning); the
      # height and animation keys have no interact of their own, so
      # they are marked used by hand.
      id = ui.next_widget_id
      height_id = id.child(0xA001_u64)
      anim_id = id.child(0xA002_u64)

      open = memory.data.get_bool(id, @default_open)
      memory.use_id(height_id)

      stored_h = memory.data.get_f64(height_id, 0.0)

      # First open with no measured height yet: the animation is seeded
      # at 0 and the block runs once under a collapsed clip — it
      # measures the content invisibly (nothing to click, nothing to
      # paint). From the next frame the reveal slides 0→1 off the
      # measured height. Without this the first toggle would flash the
      # full-height content for a frame: `AnimationManager`'s first
      # call returns the target immediately, and there is no stored
      # height to scale the reveal with yet.
      measuring = open && stored_h <= 0.0
      amount = if measuring
        ctx.animate_value_with_time(anim_id, 0.0, 0.0)
        ctx.request_repaint # run the slide from the next frame
        0.0
      else
        ctx.animate_value_with_time(anim_id, open ? 1.0 : 0.0, 0.2)
      end

      header = sheet.resolve(HEADER_CLASS)
      pad = header.box?("padding") ||
        StyleBox.new(8.0, 12.0, 8.0, 12.0)
      rounding = header.f64("rounding", 4.0)
      font_size = header.f64("font_size", style.font_size)
      family = header.str?("font_family") || style.font_family
      text_color = header.color("text_color", visuals.text_color)

      # --- header row -------------------------------------------------
      text_size = ctx.fonts_for(family).measure(@text, font_size)
      height = {text_size.y + pad.vertical,
        style.spacing.interact_size.y}.max
      rect = ui.allocate_at_least(Vec2.new(ui.available_width, height))
      response = ui.interact(rect, id, Sense.click)

      if response.clicked?
        open = !open
        memory.data.set_bool(id, open)
        response.mark_changed
        ctx.request_repaint
      end

      # State overlay on top of the class vars (same cascade as the
      # button: active beats hover).
      state = response.active? ? "active" : response.hovered? ? "hover" : nil
      state_vars = sheet.resolve(HEADER_CLASS, state)
      if (fill = state_vars.color?("background"))
        ui.painter.rect(rect, rounding, fill)
      end
      header_color = state_vars.color("text_color", text_color)

      ui.painter.text(Pos2.new(text_left(ui, rect, pad, font_size, header_color),
        rect.center.y), @text, font_size, header_color, family: family)

      # Chevron: rotates down→up with the same eased amount that
      # drives the reveal (Win11 flips it in place).
      icon = font_size * 1.1
      icon_rect = Rect.from_min_size(
        Pos2.new(rect.right - pad.right - icon, rect.center.y - icon / 2.0),
        Vec2.new(icon, icon))
      draw_chevron(ui.painter, icon_rect, amount * Math::PI, header_color)

      # --- content reveal ---------------------------------------------
      content = sheet.resolve(CONTENT_CLASS)
      cpad = content.box?("padding") ||
        StyleBox.new(4.0, 12.0, 8.0, 12.0)

      if amount > 0.001 || measuring
        content_top = rect.bottom + cpad.top
        reveal = stored_h * amount # 0 while measuring

        # Reserve the content-background slot now, back-patch it once
        # the block measured the reveal (Painter's Frame trick).
        bg_index = ui.painter.add_noop

        # Lay out unbounded, clip to the revealed window (paint AND
        # interaction — see Ui#interact) — the ScrollArea pattern.
        body = ui.child_ui(
          Rect.from_min_size(
            Pos2.new(rect.left + cpad.left, content_top),
            Vec2.new({rect.width - cpad.left - cpad.right, 0.0}.max, 1e6)),
          id: id.child(0xA003_u64))
        saved_clip = ui.painter.clip
        clip = Rect.new(
          Pos2.new({saved_clip.min.x, body.max_rect.min.x}.max,
            {saved_clip.min.y, content_top}.max),
          Pos2.new({saved_clip.max.x, body.max_rect.max.x}.min,
            {saved_clip.max.y, content_top + reveal}.min))
        ui.painter.clip = clip
        body.clip = clip

        yield body

        ui.painter.clip = saved_clip

        memory.data.set_f64(height_id, body.min_rect.height)

        # Content background (`expander.content { background }`) —
        # painted under the block, over the REVEALED slice only, so it
        # slides with the animation (always distinct from the header
        # fill above it).
        if (bg = content.color?("background"))
          bg_rect = Rect.from_min_size(Pos2.new(rect.left, rect.bottom),
            Vec2.new(rect.width, cpad.top + reveal + cpad.bottom))
          ui.painter.set(bg_index,
            RectCmd.new(saved_clip, bg_rect, content.f64("rounding", 4.0),
              bg, nil, 0.0))
        end

        # Advance the layout by the REVEALED slice only, so following
        # widgets slide with the animation (a full min_rect union
        # would hand them the end position on frame one). While
        # measuring the content occupies no space at all — it is not
        # visible yet.
        unless measuring
          ui.min_rect = ui.min_rect.union(Rect.from_min_size(
            Pos2.new(rect.left, content_top), Vec2.new(rect.width, reveal)))
          ui.cursor = Pos2.new(ui.max_rect.min.x,
            content_top + reveal + cpad.bottom)
        end
      end

      response
    end

    # Draws the optional `Icons` glyph before the label (Win11
    # settings expander look) and returns the x the label starts at.
    private def text_left(ui : Ui, rect : Rect, pad : StyleBox,
                          font_size : Float64, color : Color32) : Float64
      x = rect.left + pad.left
      if (name = @icon)
        size = font_size * 1.1
        Icons.draw(ui.painter, name, Rect.from_min_size(
          Pos2.new(x, rect.center.y - size / 2.0), Vec2.new(size, size)),
          color)
        x += size + ui.style.spacing.icon_spacing
      end
      x
    end

    # The Lucide chevron-down polyline (`icons/lucide/chevron-down.svg`:
    # m6 9 6 6 6-6) on its 24×24 grid, rotated around the icon center
    # by `angle` radians (0 = points down, π = points up). Round caps
    # via endpoint dots, like `Icons`' polyline rendering.
    private def draw_chevron(painter : Painter, rect : Rect,
                             angle : Float64, color : Color32) : Nil
      scale = {rect.width, rect.height}.min / 24.0
      cx, cy = rect.center.x, rect.center.y
      s = Math.sin(angle)
      c = Math.cos(angle)
      pts = [{6.0, 9.0}, {12.0, 15.0}, {18.0, 9.0}].map do |x, y|
        dx = (x - 12.0) * scale
        dy = (y - 12.0) * scale
        Pos2.new(cx + dx * c - dy * s, cy + dx * s + dy * c)
      end
      w = {2.0 * scale, 1.0}.max
      (1...pts.size).each { |i| painter.line(pts[i - 1], pts[i], w, color) }
      r = w / 2.0
      pts.each { |p| painter.circle_filled(p, r, color) }
    end
  end

  class Ui
    # Win11-style accordion: `ui.expander("Header", icon: :wifi) { |body| … }`.
    # The open/closed flag is system state (Memory, keyed by the
    # header's id — the app never holds it); the returned Response is
    # `changed` on the frame the header was clicked. `icon:` is an
    # optional `Icons` glyph before the label.
    def expander(text : String, default_open : Bool = false,
                  icon : Symbol? = nil, &block : Ui ->) : Response
      Expander.new(text, default_open, icon).show(self, &block)
    end
  end
end
