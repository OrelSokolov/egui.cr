# egui.cr-native container (no upstream counterpart): the GTK
# `GtkDialog` pattern on top of the modal machinery — a class of
# modals that imitate an OS window inside the application.
#
# `Context#modal` is just a scrim + content block; WindowModal turns
# that into reusable window chrome shared by every dialog-style modal:
#
#   - a title bar: title text, a close (✕) button, drag-to-move
#     (offset from the centered spot, constrained to the screen);
#   - a content area (`#body`, abstract);
#   - a GTK-style right-aligned button row along the bottom
#     (`#buttons`, abstract; `#button_row` lays the buttons out).
#
# Open state and the drag offset persist in `Memory#data`/
# `layer_sizes` keyed by the modal id, so subclasses are stateless
# value objects — build one every frame and call `#show`; it renders
# nothing while closed:
#
#   chooser = ColorChooserModal.new("fg", @color) { |c| @color = c }
#   button.on_click { chooser.open(ctx) }
#   chooser.show(ctx)   # every frame; no-op while closed
#
# While shown the modal marks `Memory#modal_open?` (interaction below
# is blocked, the screen is dimmed) and Escape closes it — the GTK
# default; `close_on_escape = false` opts out.

module Egui
  abstract class WindowModal
    # IdTypeMap child salts — high offsets so they never collide with
    # the Ui#next_widget_id counters (child(1), child(2), …) of the
    # title/body/button-row regions.
    OPEN   = 0x101_u64
    OFFSET = 0x102_u64
    TITLE  = 0x103_u64
    CLOSE  = 0x104_u64
    ROW    = 0x105_u64

    getter id : String
    property title : String
    property width : Float64
    property? close_on_escape : Bool

    def initialize(@id : String, @title : String, @width : Float64 = 400.0)
      @close_on_escape = true
    end

    def modal_id : Id
      Id.from("app_modal/#{@id}")
    end

    def open?(ctx : Context) : Bool
      ctx.memory.data.get_bool(modal_id.child(OPEN))
    end

    # Show the dialog (resets transient state via #on_open).
    def open(ctx : Context) : Nil
      mid = modal_id
      ctx.memory.use_id(mid.child(OPEN))
      ctx.memory.data.set_bool(mid.child(OPEN), true)
      on_open(ctx)
      ctx.request_repaint
    end

    def close(ctx : Context) : Nil
      mid = modal_id
      ctx.memory.use_id(mid.child(OPEN))
      ctx.memory.data.set_bool(mid.child(OPEN), false)
      ctx.request_repaint
    end

    # Hook: subclasses reset their transient state when the dialog
    # opens (e.g. the wizard jumps back to page 0).
    def on_open(ctx : Context) : Nil
    end

    # Immediate-mode entry point — call every frame; no-op while
    # closed (early-outs keep Memory/painter untouched).
    def show(ctx : Context) : Nil
      mid = modal_id
      mem = ctx.memory
      return unless mem.data.get_bool(mid.child(OPEN))

      # Escape closes (GTK default). Consumed here, before the body,
      # so the whole dialog goes even if an inner edit has focus.
      if close_on_escape? && ctx.input.consume_key(KeyCode::Escape)
        close(ctx)
        return
      end

      mem.use_id(mid.child(OPEN))
      mem.use_id(mid.child(OFFSET))
      mem.mark_modal

      style = ctx.style
      painter = ctx.painter
      pad = style.spacing.window_padding
      screen = ctx.input.screen_rect
      width = @width
      width = {width, screen.width}.min if screen.width > 0.0

      # Scrim: dim everything below (same as Context#modal).
      painter.layer = Order::Foreground
      painter.clip = screen
      painter.rect(screen, 0.0, style.visuals.modal_dim)

      # Window position: centered on last frame's size plus the drag
      # offset — clamped so the dialog always stays on screen
      # (upstream `Area` constrain).
      size = mem.layer_sizes[mid]? || Vec2.new(width, 140.0)
      offset = mem.data.get_vec2(mid.child(OFFSET))
      place = ->(off : Vec2) do
        p = Pos2.new(screen.center.x - size.x / 2.0 + off.x,
          screen.center.y - size.y / 2.0 + off.y)
        if screen.width > 0.0
          p = Pos2.new(
            p.x.clamp(screen.left, {screen.right - size.x, screen.left}.max),
            p.y.clamp(screen.top, {screen.bottom - size.y, screen.top}.max))
        end
        p
      end
      pos = place.call(offset)

      layer = LayerId.new(Order::Foreground, mid)
      title_size = style.font_size * 1.25
      title_h = title_size + pad.y

      # Title bar: drag moves the window (offset from center persists).
      title_rect = Rect.from_min_size(pos, Vec2.new(size.x, title_h))
      title_resp = ctx.interact(mid.child(TITLE), title_rect,
        Sense.click_and_drag, layer)
      if title_resp.dragged?
        offset = offset + title_resp.drag_delta
        mem.data.set_vec2(mid.child(OFFSET), offset)
        pos = place.call(offset)
      end

      # ✕ button at the title bar's right end: a modest hit target
      # with a small inset glyph (GTK-proportioned, not a giant X).
      close_side = {title_h - 6.0, 18.0}.min
      close_rect = Rect.from_min_size(
        Pos2.new(pos.x + size.x - close_side - 8.0,
          pos.y + (title_h - close_side) / 2.0),
        Vec2.new(close_side, close_side))
      close_resp = ctx.interact(mid.child(CLOSE), close_rect,
        Sense.click, layer)
      if close_resp.clicked?
        close(ctx)
        painter.layer = Order::Background
        painter.clip = Rect.infinite
        return
      end

      # Frame slot: the chrome rect is known only after the contents,
      # so reserve a noop and back-fill it (the #window trick).
      bg_index = painter.add_noop
      painter.clip = Rect.from_min_size(pos, Vec2.new(width, 1e6))

      content_min = pos + Vec2.new(pad.x, title_h + pad.y)
      ui = Ui.new(ctx, mid, Rect.from_min_size(content_min,
        Vec2.new(width - 2 * pad.x, 1e6)))
      ui.layer = layer
      body(ctx, ui)

      # Button row: its own Ui right under the body content.
      content_bottom = ui.min_rect.bottom
      row_ui = Ui.new(ctx, mid.child(ROW), Rect.from_min_size(
        Pos2.new(content_min.x, content_bottom + pad.y),
        Vec2.new(width - 2 * pad.x, 1e6)))
      row_ui.layer = layer
      buttons(ctx, row_ui)
      bottom = {row_ui.min_rect.bottom,
        content_bottom + style.spacing.interact_size.y}.max

      outer = Rect.new(pos, Pos2.new(
        {ui.min_rect.right + pad.x, pos.x + width}.max,
        bottom + pad.y))
      mem.layer_sizes[mid] = outer.size

      painter.clip = outer
      painter.set(bg_index, RectCmd.new(outer, outer, 8.0,
        style.visuals.window_fill, style.visuals.window_stroke, 1.0))
      painter.text(Pos2.new(pos.x + pad.x, pos.y + title_h / 2.0),
        @title, title_size, style.visuals.title_color)
      painter.line(Pos2.new(pos.x, pos.y + title_h),
        Pos2.new(outer.right, pos.y + title_h), 1.0,
        style.visuals.separator_color)
      if close_resp.hovered?
        painter.rect(close_rect, 3.0, style.visuals.button_hovered)
      end
      # The glyph sits in an inner square (~45% of the hit rect).
      inset = close_side * 0.28
      glyph_rect = Rect.from_min_size(
        close_rect.min + Vec2.new(inset, inset),
        Vec2.new(close_side - 2 * inset, close_side - 2 * inset))
      Icons.draw(painter, :close, glyph_rect,
        close_resp.hovered? ? style.visuals.text_color : style.visuals.title_color, 1.5)

      painter.layer = Order::Background
      painter.clip = Rect.infinite
    end

    # Dialog content between the title bar and the button row.
    abstract def body(ctx : Context, ui : Ui) : Nil

    # The bottom button strip (use #button_row for GTK-style layout).
    abstract def buttons(ctx : Context, ui : Ui) : Nil

    # GTK-style right-aligned button row: measure the labels, pin the
    # row to the right edge, paint + interact each button. `disabled`
    # ids gray out and come back clicked = false (their rects still
    # register, so interaction state survives like in #enabled).
    protected def button_row(ui : Ui, buttons : Array(Tuple(Id, String)),
                             disabled : Array(Id) = [] of Id) : Array(Bool)
      ctx = ui.ctx
      style = ui.style
      font_size = style.font_size
      pad = style.spacing.button_padding
      h = style.spacing.interact_size.y
      gap = style.spacing.item_spacing.x

      sizes = buttons.map do |_, label|
        Vec2.new(
          {ctx.fonts.measure(label, font_size).x + 2 * pad.x,
           style.spacing.interact_size.x}.max, h)
      end
      total = sizes.sum(&.x) + gap * (buttons.size - 1)
      x = ui.max_rect.right - total
      y = ui.cursor.y

      clicked = [] of Bool
      buttons.each_with_index do |(bid, label), i|
        size = sizes[i]
        rect = Rect.from_min_size(Pos2.new(x, y), size)
        x += size.x + gap

        off = disabled.includes?(bid)
        ctx.memory.push_disabled if off
        resp = ui.interact(rect, bid, Sense.click | Sense::Focusable)
        ctx.memory.pop_disabled if off

        visuals = style.visuals
        fill = visuals.button_fill(resp.hovered?, resp.active?)
        fill = visuals.fade_color(fill, 0.55) if off
        ui.painter.rect(rect, 4.0, fill, visuals.border_color, 1.0)
        text_color = off ? visuals.fade_color(visuals.text_color, 0.5) :
                           visuals.text_color
        tw = ctx.fonts.measure(label, font_size).x
        ui.painter.text(Pos2.new(rect.center.x - tw / 2.0, rect.center.y),
          label, font_size, text_color)
        resp.paint_focus_ring
        clicked << (resp.clicked? && !off)
      end

      ui.min_rect = ui.min_rect.union(
        Rect.from_min_size(Pos2.new(ui.max_rect.right - total, y),
          Vec2.new(total, h)))
      ui.cursor = Pos2.new(ui.max_rect.min.x,
        y + h + style.spacing.item_spacing.y)
      clicked
    end
  end
end
