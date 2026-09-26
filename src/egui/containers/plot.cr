# A slim plot widget (upstream counterpart: the `egui_plot` crate —
# deliberately reduced to its most-used slice): line and scatter series
# over a shared data-coordinate system, auto-fit bounds, drag-to-pan,
# wheel-to-zoom (pointer-anchored), grid + corner axis labels, legend.
#
#   Egui::Plot.new("wave", height: 220).show(ui) do |p|
#     p.line("sin", points) # Array({Float64, Float64})
#     p.points("peaks", peaks)
#   end
#
# Bounds live in `Memory#data` keyed by the plot id; `auto` re-fits
# every frame until the user pans or zooms (then they stay put — no
# reset API yet, delete the id's cells to refit). `fixed_bounds` pins
# the view instead of auto-fitting (for live plots).
#
# `animated: true` turns the plot into a live one: once the user pans
# or zooms away from the default view, a "reset view" pill (custom
# label via `#reset_label`) appears top-center; clicking it — or
# double-clicking the plot — snaps back to the default view. The pill
# is not animated-only: any plot that leaves its default view shows it
# (unless disabled via `reset_button: false`).
#
# `draggable: false` makes the plot read-only: no pan, no wheel zoom,
# no reset pill — it keeps showing the default (auto-fit / fixed)
# bounds and only repaints when new data arrives.

module Egui
  class Plot
    include Widget

    alias Point = Tuple(Float64, Float64)

    @fixed : {Float64, Float64, Float64, Float64}? = nil

    SERIES_COLORS = ->(v : Visuals, i : Int32) do
      palette = {v.selection_fill, v.hyperlink_color,
        Color32.rgb(200, 100, 30), Color32.rgb(120, 180, 60),
        Color32.rgb(180, 60, 160)}
      palette[i % palette.size]
    end

    def initialize(id : String, @height : Float64 = 200.0,
                   @animated : Bool = false, @draggable : Bool = true,
                   @reset_button : Bool = true)
      @pid = Id.from("plot/#{id}")
      @lines = [] of {String, Array(Point), Color32?}
      @dots = [] of {String, Array(Point), Color32?}
      @reset_label = "Reset view"
    end

    # Live-plot mode: pan/zoom deviate from the default view, and a
    # reset pill (or a double-click) returns to it.
    def animated(flag : Bool = true) : Plot
      @animated = flag
      self
    end

    # Read-only mode: keep the default view (no pan, no wheel zoom, no
    # reset pill); the plot still repaints every frame when animated.
    def draggable(flag : Bool = true) : Plot
      @draggable = flag
      self
    end

    # Show the reset pill once the view deviates from the default
    # (default true). `reset_button(false)` hides it — then only a
    # double-click (animated plots) can restore the default view.
    def reset_button(flag : Bool = true) : Plot
      @reset_button = flag
      self
    end

    # Custom text for the reset pill (default "Reset view").
    def reset_label(text : String) : Plot
      @reset_label = text
      self
    end

    # Pin the visible data rectangle instead of auto-fitting (used for
    # live-scrolling plots). Ignored once the user pans or zooms —
    # interaction takes over, exactly like with auto-fit.
    def fixed_bounds(min_x : Float64, min_y : Float64,
                     max_x : Float64, max_y : Float64) : Plot
      @fixed = {min_x, min_y, max_x, max_y}
      self
    end

    # `color` overrides the palette color for this series.
    def line(name : String, points : Array(Point),
             color : Color32? = nil) : Nil
      @lines << {name, points, color}
    end

    def points(name : String, points : Array(Point),
               color : Color32? = nil) : Nil
      @dots << {name, points, color}
    end

    # Widget entry point (`ui.add` / `ui.plot`); the series-collection
    # block has already run by the time #show draws.
    def ui(ui : Ui) : Response
      show(ui)
    end

    def show(ui : Ui) : Response
      ctx = ui.ctx
      mem = ctx.memory
      style = ui.style
      visuals = style.visuals

      rect = ui.allocate_at_least(
        Vec2.new(ui.available_width, @height))
      response = ui.interact(rect, @pid,
        @draggable ? Sense.click | Sense.drag : Sense.none)

      # Wheel capture: a draggable plot is a scroll sink like a
      # ScrollArea viewport or a textarea — register for Memory's
      # scroll arbitration so that, with the pointer over the plot,
      # the wheel zooms the plot and an enclosing ScrollArea no
      # longer scrolls the page underneath.
      mem.register_scroll_area(@pid, rect, ui.layer) if @draggable

      # --- pan / zoom mutate the stored bounds --------------------------
      auto = mem.data.get_int(@pid.child(3), 1) == 1
      # Animated plots: a double-click anywhere on the plot snaps the
      # view back to the default (fixed bounds / auto-fit).
      if @animated && @draggable && !auto && response.double_clicked?
        auto = true
      end
      bounds : {Vec2, Vec2}? = nil
      if auto
        if f = @fixed
          bounds = {Vec2.new(f[0], f[1]), Vec2.new(f[2], f[3])}
        else
          bounds = compute_bounds
        end
      else
        min = mem.data.get_vec2(@pid.child(1), Vec2.zero)
        max = mem.data.get_vec2(@pid.child(2), Vec2.new(1.0, 1.0))
        bounds = {min, max}
      end

      if (b = bounds) && @draggable && response.dragged? &&
         response.drag_delta.length > 0.0
        d = response.drag_delta
        sx = span_x(b) / rect.width
        sy = span_y(b) / rect.height
        min = b[0] - Vec2.new(d.x * sx, -d.y * sy)
        max = b[1] - Vec2.new(d.x * sx, -d.y * sy)
        bounds = {min, max}
        store(mem, bounds.not_nil!)
        auto = false
      end

      # Zoom only when the plot owns this frame's wheel delta — i.e.
      # it won scroll arbitration (pointer inside the plot, no higher
      # scroll sink above it); see Memory#register_scroll_area.
      scroll = ctx.input.scroll
      if @draggable && response.hovered? && mem.active_scroll_area? == @pid &&
         !scroll.y.zero? && (b = bounds) &&
         (z = zoom(scroll.y > 0 ? 0.9 : 1.1, rect, b, ctx))
        bounds = z
        store(mem, z)
        auto = false
      end

      if auto && (b = bounds)
        store(mem, b)
      end
      mem.data.set_int(@pid.child(3), auto ? 1 : 0)
      mem.use_id(@pid.child(1))
      mem.use_id(@pid.child(2))
      mem.use_id(@pid.child(3))

      return response if bounds.nil?

      min, max = bounds.not_nil!

      # --- draw -----------------------------------------------------------
      painter = ctx.painter
      outer_clip = painter.clip
      clip_min = Pos2.new({outer_clip.min.x, rect.min.x}.max,
        {outer_clip.min.y, rect.min.y}.max)
      clip_max = Pos2.new({outer_clip.max.x, rect.max.x}.min,
        {outer_clip.max.y, rect.max.y}.min)
      painter.clip = Rect.new(clip_min, clip_max)

      painter.rect(rect, 0.0, nil, visuals.separator_color, 1.0)

      grid = visuals.fade_color(visuals.separator_color, 0.5)
      4.times do |i|
        gy = rect.min.y + rect.height * (i + 1) / 5.0
        painter.line(Pos2.new(rect.min.x, gy), Pos2.new(rect.max.x, gy),
          1.0, grid)
        gx = rect.min.x + rect.width * (i + 1) / 5.0
        painter.line(Pos2.new(gx, rect.min.y), Pos2.new(gx, rect.max.y),
          1.0, grid)
      end

      to_screen = ->(p : Point) do
        x = rect.min.x + (p[0] - min.x) / span_x({min, max}) * rect.width
        y = rect.max.y - (p[1] - min.y) / span_y({min, max}) * rect.height
        Pos2.new(x, y)
      end

      @lines.each_with_index do |(name, pts, c), i|
        color = c || SERIES_COLORS.call(visuals, i)
        pts.each_cons(2) do |pair|
          painter.line(to_screen.call(pair[0]), to_screen.call(pair[1]),
            2.0, color)
        end
      end
      @dots.each_with_index do |(name, pts, c), i|
        color = c || SERIES_COLORS.call(visuals, @lines.size + i)
        pts.each do |p|
          painter.circle_filled(to_screen.call(p), 2.5, color)
        end
      end

      painter.clip = outer_clip

      # axis labels + legend (unclipped — small text at the frame):
      # y-range top-left/bottom-left, x-range bottom-right/top-right,
      # legend top-right BELOW the min.x label so the two never
      # overlap (upstream egui_plot keeps the legend top-right too).
      small = style.font_size * 0.8
      painter.text(Pos2.new(rect.left + 4.0, rect.min.y + small * 0.5),
        fmt(max.y), small, visuals.text_color)
      painter.text(Pos2.new(rect.left + 4.0, rect.max.y - small * 0.5),
        fmt(min.y), small, visuals.text_color)
      painter.text(Pos2.new(rect.max.x - 60.0, rect.max.y - small * 0.5),
        fmt(max.x), small, visuals.text_color)
      painter.text(Pos2.new(rect.max.x - 60.0, rect.min.y + small * 0.5),
        fmt(min.x), small, visuals.text_color)

      (@lines + @dots).each_with_index do |(name, _, c), i|
        ts = ctx.fonts.measure(name, small)
        ly = rect.min.y + small * 2.2 + i.to_f64 * small * 1.4
        lx = rect.max.x - 26.0 - ts.x # right-aligned text end
        painter.line(Pos2.new(lx - 18.0, ly + small * 0.4),
          Pos2.new(lx - 4.0, ly + small * 0.4), 2.0,
          c || SERIES_COLORS.call(visuals, i))
        painter.text(Pos2.new(lx, ly), name, small,
          visuals.text_color)
      end

      # Once the view deviates from the default, show a reset pill
      # top-center (drawn after the clip restore so it is never cut).
      # Interacted after the plot rect, so hit-testing ranks it topmost
      # and it wins the click. Hidden via `reset_button: false`.
      if @reset_button && !auto
        small = style.font_size * 0.8
        ts = ctx.fonts.measure(@reset_label, small)
        size = Vec2.new(ts.x + 16.0, ts.y + 8.0)
        box = Rect.from_min_size(
          Pos2.new(rect.center.x - size.x / 2.0, rect.min.y + 6.0), size)
        bresp = ui.interact(box, @pid.child(4), Sense.click)
        if bresp.clicked?
          # Default view from next frame on (this frame already drew
          # with the user's bounds).
          mem.data.set_int(@pid.child(3), 1)
        else
          painter.rect(box, rounding: 4.0,
            fill: visuals.button_fill(bresp.hovered?, bresp.active?),
            stroke_color: visuals.button_stroke, stroke_width: 1.0)
          painter.text(Pos2.new(box.left + (box.width - ts.x) / 2.0,
            box.center.y), @reset_label, small, visuals.text_color)
          bresp.on_hover_cursor(CursorIcon::Pointer)
        end
        mem.use_id(@pid.child(4))
      end

      if @draggable
        response.on_hover_cursor(CursorIcon::Grab)
        response.on_hover_and_drag_cursor(CursorIcon::Grabbing)
      end
      response
    end

    private def span_x(b : {Vec2, Vec2}) : Float64
      {b[1].x - b[0].x, 1e-9}.max
    end

    private def span_y(b : {Vec2, Vec2}) : Float64
      {b[1].y - b[0].y, 1e-9}.max
    end

    private def store(mem : Memory, b : {Vec2, Vec2}) : Nil
      mem.data.set_vec2(@pid.child(1), b[0])
      mem.data.set_vec2(@pid.child(2), b[1])
    end

    # Zoom by `factor` around the pointer (or the rect center when the
    # pointer is unknown); nil when nothing to zoom.
    private def zoom(factor : Float64, rect : Rect,
                      bounds : {Vec2, Vec2}?, ctx : Context) : {Vec2, Vec2}?
      return nil unless bounds
      min, max = bounds
      center = ctx.input.pointer_pos || rect.center
      # data coordinate under the zoom anchor
      ax = min.x + (center.x - rect.min.x) / rect.width * span_x(bounds)
      ay = max.y - (center.y - rect.min.y) / rect.height * span_y(bounds)

      new_min_x = ax - (ax - min.x) * factor
      new_max_x = ax + (max.x - ax) * factor
      new_min_y = ay - (ay - min.y) * factor
      new_max_y = ay + (max.y - ay) * factor
      {Vec2.new(new_min_x, new_min_y), Vec2.new(new_max_x, new_max_y)}
    end

    private def compute_bounds : {Vec2, Vec2}?
      all = (@lines + @dots).flat_map &.[1]
      return nil if all.empty?
      xs = all.map &.[0]
      ys = all.map &.[1]
      # 5% breathing room; flat series get a fixed span so the line is
      # centered instead of clipped to zero height.
      pad_x = xs.max == xs.min ? 0.5 : (xs.max - xs.min) * 0.05
      pad_y = ys.max == ys.min ? 1.0 : (ys.max - ys.min) * 0.05
      {Vec2.new(xs.min - pad_x, ys.min - pad_y),
       Vec2.new(xs.max + pad_x, ys.max + pad_y)}
    end

    private def fmt(v : Float64) : String
      v.abs < 1e6 ? (v.abs < 0.01 && v != 0.0 ? "%.1e" % v : "%.2f" % v) : "%.1e" % v
    end
  end
end
