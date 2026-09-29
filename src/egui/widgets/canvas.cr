# egui.cr-native pixel canvas (no upstream counterpart — egui delegates
# raster editing to the app): a retained RGBA8 pixel buffer shown as a
# (nearest-sampled) texture, with the classic Paint-style raster
# operations built in — Bresenham lines, rect/ellipse (outline, filled,
# thickness), flood fill, region blit — plus interaction reporting in
# PIXEL coordinates (pointer, drag start/stop, both mouse buttons: the
# left button draws with the foreground color, the right with the
# background color, exactly like MS Paint).
#
#   canvas = Egui::Canvas.new("paint", 640, 480)
#   canvas.line(0, 0, 100, 60, Egui::Color32::BLACK)
#   ...
#   canvas.show(ui) do |ia|        # or ui.canvas(canvas) { }
#     if ia.dragging? && ia.drag_button == :primary
#       canvas.line(ia.last_px.x, ...) # app-driven stroke
#     end
#   end
#   canvas.flush(ctx) if canvas.dirty? # same-frame texture upload
#
# The buffer lives in the widget instance (a handle the app owns for
# the whole session); the GPU texture is a stream texture
# (`TextureRegistry#create_stream`/`#update`) recreated on resize,
# released through `#destroy_later` so an idle-frame command replay
# never samples a dead texture.

module Egui
  class Canvas
    include Widget

    # Per-frame interaction report. Positions are in CANVAS pixels
    # (already divided by the zoom `scale`), nil when the pointer is
    # off the canvas.
    class Interaction
      getter response : Response
      getter pointer_px : Pos2?
      getter? dragging : Bool
      # Which button a running drag started with (:primary draws with
      # the fg color in Paint, :secondary with the bg color).
      getter drag_button : Symbol?
      getter drag_start_px : Pos2?
      getter? drag_started : Bool
      getter? drag_stopped : Bool
      # Completed clicks this frame (press+release inside the canvas).
      getter click_px : Pos2?
      getter secondary_click_px : Pos2?
      getter double_click_px : Pos2?

      def initialize(@response, @pointer_px, @dragging, @drag_button,
                     @drag_start_px, @drag_started, @drag_stopped,
                     @click_px, @secondary_click_px, @double_click_px)
      end

      # The button a click completed with (nil when no click this
      # frame): :primary / :secondary.
      def clicked_button : Symbol?
        return :primary if @click_px
        :secondary if @secondary_click_px
      end
    end

    getter width : Int32
    getter height : Int32
    # Zoom: screen pixels per canvas pixel (integer, ≥ 1).
    property scale : Int32 = 1
    getter? dirty : Bool
    getter texture_id : UInt64

    @pid : Id
    @pixels : Bytes
    @texture_w : Int32 = 0
    @texture_h : Int32 = 0
    @dragging : Symbol? = nil
    @drag_start : Pos2? = nil
    @pending_secondary_click : Pos2? = nil

    def initialize(id : String, width : Int32, height : Int32,
                   fill : Color32 = Color32.new(255, 255, 255))
      @pid = Id.from("canvas/#{id}")
      @width = width
      @height = height
      @pixels = Bytes.new(width.to_i64 * height * 4)
      fill_with(fill)
      @dirty = true
      @texture_id = 0_u64
    end

    def inspector_label : String?
      "canvas #{width}×#{height}"
    end

    # --- pixel buffer ---------------------------------------------------

    # The raw RGBA8 buffer (top-down, stride width*4). Read-only use;
    # mutations through this reference bypass the dirty flag — call
    # #mark_dirty after writing.
    getter pixels : Bytes

    def mark_dirty : Nil
      @dirty = true
    end

    def inside?(x : Int32, y : Int32) : Bool
      x >= 0 && y >= 0 && x < @width && y < @height
    end

    def [](x : Int32, y : Int32) : Color32
      i = (y.to_i64 * @width + x) * 4
      Color32.new(@pixels[i], @pixels[i + 1], @pixels[i + 2], @pixels[i + 3])
    end

    # Solid write (alpha overwrite); out-of-bounds writes are ignored.
    def []=(x : Int32, y : Int32, color : Color32) : Nil
      return unless inside?(x, y)
      i = (y.to_i64 * @width + x) * 4
      @pixels[i] = color.r
      @pixels[i + 1] = color.g
      @pixels[i + 2] = color.b
      @pixels[i + 3] = color.a
      @dirty = true
    end

    # Coverage blend: `cov` in 0..255 multiplies the incoming color's
    # alpha (antialiased glyph rendering).
    def blend(x : Int32, y : Int32, color : Color32, cov : Int32) : Nil
      return unless inside?(x, y)
      a = (color.a.to_i32 * cov) // 255
      return if a <= 0
      i = (y.to_i64 * @width + x) * 4
      if a >= 255
        @pixels[i] = color.r
        @pixels[i + 1] = color.g
        @pixels[i + 2] = color.b
        @pixels[i + 3] = color.a
      else
        # NB: this Crystal build does NOT promote UInt8*Int32 — cast
        # every operand explicitly or the multiply overflows UInt8.
        ia = 255 - a
        @pixels[i] = ((color.r.to_i32 * a + @pixels[i].to_i32 * ia) / 255).to_u8
        @pixels[i + 1] = ((color.g.to_i32 * a + @pixels[i + 1].to_i32 * ia) / 255).to_u8
        @pixels[i + 2] = ((color.b.to_i32 * a + @pixels[i + 2].to_i32 * ia) / 255).to_u8
        @pixels[i + 3] = 255_u8
      end
      @dirty = true
    end

    def fill_with(color : Color32) : Nil
      i = 0
      while i < @pixels.size
        @pixels[i] = color.r
        @pixels[i + 1] = color.g
        @pixels[i + 2] = color.b
        @pixels[i + 3] = color.a
        i += 4
      end
      @dirty = true
    end

    # Replace the whole buffer (must be width*height*4 bytes, RGBA8).
    def replace_pixels(data : Bytes) : Nil
      raise "canvas buffer size mismatch" unless data.size == @pixels.size
      @pixels.copy_from(data)
      @dirty = true
    end

    def snapshot : Bytes
      @pixels.dup
    end

    def restore(data : Bytes) : Nil
      replace_pixels(data)
    end

    # Undo across resizes: a snapshot from a different canvas size
    # resizes the canvas back and then restores the pixels.
    def restore_sized(w : Int32, h : Int32, data : Bytes) : Nil
      if w != @width || h != @height
        @width = w
        @height = h
        @pixels = Bytes.new(w.to_i64 * h * 4)
        if data.size != @pixels.size
          raise "canvas buffer size mismatch"
        end
      end
      replace_pixels(data)
    end

    # New dimensions; content is NOT preserved (call #snapshot/#restore
    # around it when needed). The GPU texture is recreated lazily on
    # the next #show.
    def resize(width : Int32, height : Int32,
               fill : Color32 = Color32.new(255, 255, 255)) : Nil
      @width = width
      @height = height
      @pixels = Bytes.new(width.to_i64 * height * 4)
      fill_with(fill)
    end

    # --- raster operations ----------------------------------------------

    # Horizontal span, inclusive of both ends.
    def span(x0 : Int32, x1 : Int32, y : Int32, color : Color32) : Nil
      lo = {x0, x1}.min
      hi = {x0, x1}.max
      x = lo
      while x <= hi
        self[x, y] = color
        x += 1
      end
    end

    def rect_fill(x : Int32, y : Int32, w : Int32, h : Int32,
                  color : Color32) : Nil
      yy = y
      while yy < y + h
        span(x, x + w - 1, yy, color)
        yy += 1
      end
    end

    # Outline of `width` device pixels, drawn inside the rect.
    def rect_outline(x : Int32, y : Int32, w : Int32, h : Int32,
                     color : Color32, width : Int32 = 1) : Nil
      t = {width, w, h}.min
      span(x, x + w - 1, y, color)
      span(x, x + w - 1, y + h - 1, color)
      yy = y
      while yy < y + h
        span(x, x + t - 1, yy, color)
        span(x + w - t, x + w - 1, yy, color)
        yy += 1
      end
    end

    # Bresenham line stamped with a square brush `width` px across.
    def line(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32,
             color : Color32, width : Int32 = 1) : Nil
      r = {width, 1}.max // 2
      dx = (x1 - x0).abs
      dy = -(y1 - y0).abs
      sx = x0 < x1 ? 1 : -1
      sy = y0 < y1 ? 1 : -1
      err = dx + dy
      x = x0
      y = y0
      loop do
        (-r..r).each do |oy|
          (-r..r).each do |ox|
            self[x + ox, y + oy] = color
          end
        end
        break if x == x1 && y == y1
        e2 = 2 * err
        if e2 >= dy
          err += dy
          x += sx
        end
        if e2 <= dx
          err += dx
          y += sy
        end
      end
    end

    # One brush dab centered on (x, y): shape is :square, :circle,
    # :fslash (╲) or :bslash (╱); `size` is the full diameter.
    def stamp(x : Int32, y : Int32, size : Int32, shape : Symbol,
              color : Color32) : Nil
      r = {size, 1}.max // 2
      case shape
      when :circle
        rr = (size / 2.0) * (size / 2.0)
        (-r..r).each do |oy|
          (-r..r).each do |ox|
            self[x + ox, y + oy] = color if ox * ox + oy * oy <= rr
          end
        end
      when :fslash
        (-r..r).each do |i|
          self[x + i, y + i] = color
          self[x + i + 1, y + i] = color if size > 2
        end
      when :bslash
        (-r..r).each do |i|
          self[x + i, y - i] = color
          self[x + i + 1, y - i] = color if size > 2
        end
      else # :square
        (-r..r).each do |oy|
          (-r..r).each do |ox|
            self[x + ox, y + oy] = color
          end
        end
      end
    end

    # Freehand stroke through an already-stamped dab trail is just
    # repeated #line calls in the app; brushes with round/diagonal
    # stamps use this segmented variant.
    def brush_line(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32,
                   size : Int32, shape : Symbol, color : Color32) : Nil
      if shape == :square
        line(x0, y0, x1, y1, color, size)
      else
        dx = (x1 - x0).abs
        dy = (y1 - y0).abs
        steps = {(dx + dy) * 2, 1}.max
        (0..steps).each do |i|
          t = i.to_f64 / steps
          stamp((x0 + (x1 - x0) * t).round.to_i,
            (y0 + (y1 - y0) * t).round.to_i, size, shape, color)
        end
      end
    end

    # Ellipse inscribed in the bounding rect (x, y, w, h). Midpoint
    # algorithm (both quadrant pairs), every boundary pixel stamped for
    # `width` thickness.
    def ellipse_outline(x : Int32, y : Int32, w : Int32, h : Int32,
                        color : Color32, width : Int32 = 1) : Nil
      return if w < 1 || h < 1
      a = w // 2
      b = h // 2
      x0 = x + a
      y0 = y + b
      r = {width, 1}.max // 2
      plot4 = ->(px : Int32, py : Int32) do
        (-r..r).each do |oy|
          (-r..r).each do |ox|
            self[px + ox, py + oy] = color
          end
        end
      end
      # Region 1: |slope| < 1
      aa = a * a
      bb = b * b
      aa2 = aa * 2
      bb2 = bb * 2
      px = 0
      py = b
      d1 = bb - aa * b + aa / 4.0
      dx = bb2 * px
      dy = aa2 * py
      while dx < dy
        plot4.call(x0 + px, y0 + py)
        plot4.call(x0 - px, y0 + py)
        plot4.call(x0 + px, y0 - py)
        plot4.call(x0 - px, y0 - py)
        if d1 < 0
          px += 1
          dx += bb2
          d1 += dx + bb
        else
          px += 1
          py -= 1
          dx += bb2
          dy -= aa2
          d1 += dx - dy + bb
        end
      end
      # Region 2
      d2 = bb * (px + 0.5) * (px + 0.5) + aa * (py - 1) * (py - 1) - aa * bb
      while py >= 0
        plot4.call(x0 + px, y0 + py)
        plot4.call(x0 - px, y0 + py)
        plot4.call(x0 + px, y0 - py)
        plot4.call(x0 - px, y0 - py)
        if d2 > 0
          py -= 1
          dy -= aa2
          d2 += aa - dy
        else
          py -= 1
          px += 1
          dx += bb2
          dy -= aa2
          d2 += dx - dy + aa
        end
      end
    end

    def ellipse_fill(x : Int32, y : Int32, w : Int32, h : Int32,
                     color : Color32) : Nil
      return if w < 1 || h < 1
      cx = x + (w - 1) / 2.0
      cy = y + (h - 1) / 2.0
      rx = w / 2.0
      ry = h / 2.0
      if ry < 1.0
        span(x, x + w - 1, (cy - 0.5).round.to_i, color)
        return
      end
      top = (cy - ry).ceil.to_i
      bot = (cy + ry).floor.to_i
      (top..bot).each do |yy|
        t = (yy - cy) / ry
        t = 0.0 if t.abs > 1.0
        dx = rx * Math.sqrt(1 - t * t)
        span((cx - dx).round.to_i, (cx + dx).round.to_i, yy, color)
      end
    end

    # Scanline flood fill (4-connected, exact color match).
    def flood_fill(x : Int32, y : Int32, color : Color32) : Nil
      return unless inside?(x, y)
      target = self[x, y]
      return if target == color
      stack = [{x, y}]
      while (pt = stack.pop?)
        px, py = pt
        next unless inside?(px, py)
        next unless self[px, py] == target
        # walk left
        lx = px
        while lx > 0 && self[lx - 1, py] == target
          lx -= 1
        end
        rx = px
        while rx < @width - 1 && self[rx + 1, py] == target
          rx += 1
        end
        (lx..rx).each do |i|
          self[i, py] = color
        end
        (lx..rx).each do |i|
          stack << {i, py - 1} if py > 0 && self[i, py - 1] == target
          stack << {i, py + 1} if py < @height - 1 && self[i, py + 1] == target
        end
      end
      @dirty = true
    end

    # RGB inversion of the whole canvas (Paint: Image → Invert Colors).
    def invert : Nil
      i = 0
      while i < @pixels.size
        @pixels[i] = (255 - @pixels[i]).to_u8
        @pixels[i + 1] = (255 - @pixels[i + 1]).to_u8
        @pixels[i + 2] = (255 - @pixels[i + 2]).to_u8
        i += 4
      end
      @dirty = true
    end

    # Copy a w×h region out (RGBA8); out-of-bounds areas read as
    # transparent black.
    def region(x : Int32, y : Int32, w : Int32, h : Int32) : Bytes
      out = Bytes.new(w.to_i64 * h * 4)
      (0...h).each do |yy|
        (0...w).each do |xx|
          next unless inside?(x + xx, y + yy)
          src = ((y + yy).to_i64 * @width + x + xx) * 4
          dst = (yy.to_i64 * w + xx) * 4
          out[dst] = @pixels[src]
          out[dst + 1] = @pixels[src + 1]
          out[dst + 2] = @pixels[src + 2]
          out[dst + 3] = @pixels[src + 3]
        end
      end
      out
    end

    # Blit an RGBA8 w×h buffer at (x, y). `transparent_color` skips
    # matching pixels (Paint's transparent-selection mode).
    def blit(x : Int32, y : Int32, data : Bytes, w : Int32, h : Int32,
             transparent_color : Color32? = nil) : Nil
      (0...h).each do |yy|
        (0...w).each do |xx|
          src = (yy.to_i64 * w + xx) * 4
          c = Color32.new(data[src], data[src + 1], data[src + 2], data[src + 3])
          next if transparent_color && c == transparent_color
          self[x + xx, y + yy] = c
        end
      end
    end

    # Erase a w×h region down to one color (selection lift/cut).
    def erase_region(x : Int32, y : Int32, w : Int32, h : Int32,
                     color : Color32) : Nil
      (0...h).each do |yy|
        (0...w).each do |xx|
          self[x + xx, y + yy] = color
        end
      end
    end

    # --- widget plumbing -------------------------------------------------

    def ui(ui : Ui) : Response
      response = show(ui).response
      response.widget_text = "canvas"
      response
    end

    # Allocate, interact, paint. Returns this frame's Interaction.
    def show(ui : Ui) : Interaction
      ctx = ui.ctx
      rect = ui.allocate_at_least(
        Vec2.new((@width * @scale).to_f64, (@height * @scale).to_f64))
      response = ui.interact(rect, @pid, Sense.click_and_drag)

      ensure_texture(ctx)

      # White backing so a not-yet-uploaded stream texture (first
      # frame) still shows a blank canvas, then the image itself —
      # NEAREST: texels must not blur under zoom.
      painter = ui.painter
      painter.rect(rect, 0.0, Color32.new(255, 255, 255))
      unless @texture_id.zero?
        painter.image(rect, @texture_id, nearest: true)
      end
      flush(ctx)

      # --- interaction in pixel coordinates -----------------------------
      input = ctx.input
      pointer = input.pointer_pos
      hover_px = pointer.try { |p| to_px(p, rect) if rect.contains?(p) }

      drag_started = false
      drag_stopped = false
      click_px : Pos2? = nil
      secondary_click_px : Pos2? = nil

      # Primary drag: egui's interact tracks press/drag/release — but
      # with a Click|Drag sense the drag only classifies after a few
      # pixels of movement, while Paint strokes must start on PRESS (a
      # pencil click is a dot). So a press inside the canvas counts as
      # a drag start too.
      if @dragging != :primary &&
         (response.drag_started? || response.pressed?)
        @dragging = :primary
        @drag_start = hover_px
        drag_started = true
      end
      # Secondary press inside the canvas starts a right-drag.
      if input.secondary_pressed? && (sp = input.secondary_pos) &&
         rect.contains?(sp) && @dragging.nil?
        @dragging = :secondary
        @drag_start = to_px(sp, rect)
        @pending_secondary_click = @drag_start
        drag_started = true
      end

      case @dragging
      when :primary
        if response.drag_stopped? || !input.pointer_down?
          drag_stopped = true
          @dragging = nil
        end
      when :secondary
        if input.secondary_released?
          drag_stopped = true
          secondary_click_px = @pending_secondary_click
          @pending_secondary_click = nil
          @dragging = nil
        end
      end

      click_px = hover_px if response.clicked?
      double_click_px = hover_px if response.double_clicked?

      dragging = !@dragging.nil?
      Interaction.new(response, hover_px, dragging, @dragging,
        @drag_start, drag_started, drag_stopped,
        click_px, secondary_click_px, double_click_px)
    end

    # Upload pending pixels NOW (show/flush otherwise catch it a frame
    # later) — call after this frame's tool processing.
    def flush(ctx : Context) : Nil
      return unless @dirty && !@texture_id.zero?
      ctx.textures.update(@texture_id, @texture_w, @texture_h, @pixels)
      @dirty = false
    end

    # Release the GPU texture (app shutdown / canvas replacement).
    def destroy_texture(ctx : Context) : Nil
      unless @texture_id.zero?
        ctx.textures.destroy_later(@texture_id)
        @texture_id = 0_u64
      end
    end

    private def ensure_texture(ctx : Context) : Nil
      if @texture_id.zero? || @texture_w != @width || @texture_h != @height
        destroy_texture(ctx)
        @texture_id = ctx.textures.create_stream(@width, @height)
        @texture_w = @width
        @texture_h = @height
        @dirty = true
      end
    end

    private def to_px(p : Pos2, rect : Rect) : Pos2
      s = @scale.to_f64
      x = ((p.x - rect.min.x) / s).floor.to_i.clamp(0, @width - 1)
      y = ((p.y - rect.min.y) / s).floor.to_i.clamp(0, @height - 1)
      Pos2.new(x.to_f64, y.to_f64)
    end
  end
end
