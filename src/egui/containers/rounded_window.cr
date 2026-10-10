# egui.cr-native container (no upstream counterpart): the rounded
# window — a whole-window shell that paints a rounded-rectangle
# backdrop AND cuts the platform window to the same shape, so a
# borderless `transparent: true` window reads as a rounded card
# floating on the desktop (the macOS Spotlight idiom; see
# examples/rounded_window.cr).
#
# The shape is recomputed from the current rect/radius every call and
# regenerated only when the geometry changed, so the "window" may be
# animated — grow with a result list, change its corner radius at
# runtime — and the platform follows one frame later. On X11/Win32
# the mask is binary (XShape / SetWindowRgn: a pixel belongs to the
# window or not, no anti-aliased edge); macOS needs no shape at all —
# its non-opaque NSWindow composites the painted rounded rect
# directly, so the shape call is a no-op there (see
# SystemPorts::Window.set_shape).
#
# Content is laid out through the Ui the block receives (the rect
# shrunk by `pad`); widgets added there paint and hit-test above the
# backdrop. `drag: true` adds an anywhere-in-the-rect native
# window-move strip UNDER the content — content widgets win
# hit-tests wherever they overlap, empty areas drag the window.
module Egui
  class RoundedWindow
    DEFAULT_RADIUS = 12.0

    getter rect : Rect   # the (screen-clamped) rounded-rect actually drawn
    getter radius : Float64

    def initialize(@ctx : Context, rect : Rect, radius : Float64 = DEFAULT_RADIUS)
      screen = @ctx.input.screen_rect
      min = Pos2.new({rect.left, screen.left}.max, {rect.top, screen.top}.max)
      max = Pos2.new({rect.right, screen.right}.min,
        {rect.bottom, screen.bottom}.min)
      @rect = Rect.new(min, Pos2.new({max.x, min.x}.max, {max.y, min.y}.max))
      half = {@rect.width, @rect.height}.min / 2.0
      @radius = radius.clamp(0.0, half)
    end

    def self.show(ctx : Context, rect : Rect, radius : Float64 = DEFAULT_RADIUS,
                  fill : Color32? = nil, stroke : Color32? = nil,
                  stroke_width : Float64 = 1.0, pad : Float64 = 12.0,
                  drag : Bool = false, id : String = "rounded_window",
                  &block : Ui ->) : Rect
      win = new(ctx, rect, radius)
      win.draw(fill, stroke, stroke_width, pad, drag, id) { |ui| block.call(ui) }
      win.rect
    end

    def draw(fill : Color32?, stroke : Color32?, stroke_width : Float64,
             pad : Float64, drag : Bool, id : String, &block : Ui ->) : Rect
      # The backdrop, under everything painted later this frame.
      painter = @ctx.painter
      painter.layer = Order::Background
      painter.clip = Rect.infinite
      painter.rect(@rect, @radius, fill || @ctx.style.visuals.panel_fill,
        stroke, stroke_width)

      apply_shape

      # Native window-move strip, registered BEFORE the content so the
      # content's widgets (same layer, later) win hit-tests on overlap.
      if drag
        resp = @ctx.interact(Id.from("#{id}/drag"), @rect,
          Sense::Drag, LayerId.background, @rect)
        SystemPorts::Window.start_drag if resp.drag_started?
      end

      ui = Ui.new(@ctx, Id.from("rounded_window/#{id}"),
        @rect.shrink(pad), Layout.top_down)
      ui.clip = @rect
      block.call(ui)

      painter.layer = Order::Background
      painter.clip = Rect.infinite
      @rect
    end

    # --- window shape --------------------------------------------------------
    #
    # Regenerate the binary mask only when the geometry changed since
    # the last call (screen size included — a WM resize retiles it).

    @@shape_key = {0, 0, 0.0, 0.0, 0.0, 0.0, 0.0}
    @@mask = Bytes.new(0)

    private def apply_shape : Nil
      screen = @ctx.input.screen_rect
      w = screen.width.round.to_i
      h = screen.height.round.to_i
      key = {w, h, @rect.left, @rect.top, @rect.width, @rect.height, @radius}
      return if key == @@shape_key
      @@shape_key = key
      @@mask = RoundedWindow.rounded_mask(w, h, @rect, @radius)
      SystemPorts::Window.set_shape(@@mask, w, h)
    end

    # Rasterize `rect` (window-local coordinates, same units as the
    # mask grid) into a window-sized 8-bit binary mask: 255 where the
    # rounded rect covers the pixel center, 0 elsewhere. Public for
    # specs. Straight-band rows are filled as whole runs; only the
    # corner rows walk per-pixel.
    def self.rounded_mask(win_w : Int32, win_h : Int32, rect : Rect,
                          radius : Float64) : Bytes
      mask = Bytes.new(win_w * win_h, 0_u8)
      cx = rect.left + rect.width / 2.0
      cy = rect.top + rect.height / 2.0
      hw = rect.width / 2.0
      hh = rect.height / 2.0
      r = radius.clamp(0.0, {hw, hh}.min)

      # Pixel centers covered by the straight body of the rect.
      body_from = {(rect.left - 0.5).ceil.to_i, 0}.max
      body_to = {(rect.right - 0.5).floor.to_i, win_w - 1}.min

      # Per-pixel x span a corner row can reach (pixel centers within
      # r of the body edge).
      corner_from = {(rect.left - r - 0.5).ceil.to_i, 0}.max
      corner_to = {(rect.right + r - 0.5).floor.to_i, win_w - 1}.min

      win_h.times do |py|
        pyc = py + 0.5
        next if pyc < rect.top || pyc >= rect.bottom
        if pyc >= rect.top + r && pyc <= rect.bottom - r
          # Straight band: everything between the corner centers is in.
          if body_to >= body_from
            mask.fill(255_u8, py * win_w + body_from, body_to - body_from + 1)
          end
        else
          dy = (pyc - cy).abs - hh + r
          dy = dy > 0.0 ? dy : 0.0
          dy2 = dy * dy
          base = py * win_w
          (corner_from..corner_to).each do |px|
            dx = (px + 0.5 - cx).abs - hw + r
            dx = dx > 0.0 ? dx : 0.0
            mask[base + px] = 255_u8 if dx * dx + dy2 <= r * r
          end
        end
      end
      mask
    end
  end
end
