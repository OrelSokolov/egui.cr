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
# reset API yet, delete the id's cells to refit).

module Egui
  class Plot
    include Widget

    alias Point = Tuple(Float64, Float64)

    SERIES_COLORS = ->(v : Visuals, i : Int32) do
      palette = {v.selection_fill, v.hyperlink_color,
        Color32.rgb(200, 100, 30), Color32.rgb(120, 180, 60),
        Color32.rgb(180, 60, 160)}
      palette[i % palette.size]
    end

    def initialize(id : String, @height : Float64 = 200.0)
      @pid = Id.from("plot/#{id}")
      @lines = [] of {String, Array(Point)}
      @dots = [] of {String, Array(Point)}
    end

    def line(name : String, points : Array(Point)) : Nil
      @lines << {name, points}
    end

    def points(name : String, points : Array(Point)) : Nil
      @dots << {name, points}
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
      response = ui.interact(rect, @pid, Sense.click | Sense.drag)

      # --- pan / zoom mutate the stored bounds --------------------------
      auto = mem.data.get_int(@pid.child(3), 1) == 1
      bounds : {Vec2, Vec2}? = nil
      if auto
        bounds = compute_bounds
      else
        min = mem.data.get_vec2(@pid.child(1), Vec2.zero)
        max = mem.data.get_vec2(@pid.child(2), Vec2.new(1.0, 1.0))
        bounds = {min, max}
      end

      if (b = bounds) && response.dragged? && response.drag_delta.length > 0.0
        d = response.drag_delta
        sx = span_x(b) / rect.width
        sy = span_y(b) / rect.height
        min = b[0] - Vec2.new(d.x * sx, -d.y * sy)
        max = b[1] - Vec2.new(d.x * sx, -d.y * sy)
        bounds = {min, max}
        store(mem, bounds.not_nil!)
        auto = false
      end

      scroll = ctx.input.scroll
      if response.hovered? && !scroll.y.zero? && (b = bounds) &&
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

      @lines.each_with_index do |(name, pts), i|
        color = SERIES_COLORS.call(visuals, i)
        pts.each_cons(2) do |pair|
          painter.line(to_screen.call(pair[0]), to_screen.call(pair[1]),
            2.0, color)
        end
      end
      @dots.each_with_index do |(name, pts), i|
        color = SERIES_COLORS.call(visuals, @lines.size + i)
        pts.each do |p|
          painter.circle_filled(to_screen.call(p), 2.5, color)
        end
      end

      painter.clip = outer_clip

      # axis labels + legend (unclipped — small text at the frame)
      small = style.font_size * 0.8
      painter.text(Pos2.new(rect.left + 4.0, rect.min.y + small * 0.5),
        fmt(max.y), small, visuals.text_color)
      painter.text(Pos2.new(rect.left + 4.0, rect.max.y - small * 0.5),
        fmt(min.y), small, visuals.text_color)
      painter.text(Pos2.new(rect.max.x - 60.0, rect.max.y - small * 0.5),
        fmt(max.x), small, visuals.text_color)
      painter.text(Pos2.new(rect.max.x - 60.0, rect.min.y + small * 0.5),
        fmt(min.x), small, visuals.text_color)

      (@lines + @dots).each_with_index do |(name, _), i|
        lx = rect.min.x + 8.0
        ly = rect.min.y + 8.0 + i.to_f64 * small * 1.4
        painter.line(Pos2.new(lx, ly + small * 0.4),
          Pos2.new(lx + 14.0, ly + small * 0.4), 2.0,
          SERIES_COLORS.call(visuals, i))
        painter.text(Pos2.new(lx + 18.0, ly), name, small,
          visuals.text_color)
      end

      response.on_hover_cursor(CursorIcon::Grab)
      response.on_hover_and_drag_cursor(CursorIcon::Grabbing)
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
