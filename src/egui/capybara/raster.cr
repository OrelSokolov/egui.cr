# CPU rasterizer for Capybara screenshots: a frame's PaintCmd list →
# straight-alpha RGBA8 buffer, no GL involved. The point is speed and
# determinism — a scenario steps frames and dumps any state to PNG without
# a window (the in-app reproduce workflow; replaces external xwd/Python
# grabbers for core UI).
#
# Fidelity is "debugging-accurate", not pixel-identical to the sokol
# backend: shapes render with analytic SDF antialiasing, gradients and
# replace-blend match, box-shadows are approximated with a linear SDF
# falloff (the backend approximates them too, just with Gouraud bands),
# Mesh3D is a no-op and textured ImageCmds draw a checker placeholder —
# unless an image renderer is installed (capybara/images.cr composites
# the registry's pixel backup). Text goes through a pluggable renderer —
# the core alone only knows metrics stubs, so
# `capybara/fonts.cr` (CrystalFonts + glyph atlas) installs the real one;
# without it text draws as outlined boxes that still show the text's
# extents.

module Egui
  module Capybara
    class Raster
      # Text rasterization hook: `(cmd, raster) -> Nil`. Installed by
      # capybara/fonts.cr (which knows Driver::AtlasFonts); the core
      # keeps no backend types.
      class_property text_renderer : (TextCmd, Raster -> Nil)?

      # Image rasterization hook: `(cmd, raster) -> Nil`. Installed by
      # capybara/images.cr (which knows the Context's TextureRegistry);
      # without it ImageCmds draw the checker placeholder.
      class_property image_renderer : (ImageCmd, Raster -> Nil)?

      getter width : Int32
      getter height : Int32
      getter pixels : Bytes # RGBA8, top-down rows

      def initialize(@width : Int32, @height : Int32, bg : Color32)
        @pixels = Bytes.new(@width * @height * 4)
        fill_rect_color(bg)
      end

      # Paint a full frame's command list (as returned by
      # `Context#end_frame` — back-to-front, clip already resolved).
      def render(commands : Array(PaintCmd)) : Nil
        commands.each do |cmd|
          case cmd
          in RectCmd    then rect_cmd(cmd)
          in TextCmd    then text_cmd(cmd)
          in CircleCmd  then circle_cmd(cmd)
          in LineCmd    then line_cmd(cmd)
          in TriCmd     then tri_cmd(cmd)
          in ArcCmd     then arc_cmd(cmd)
          in ShadowCmd  then shadow_cmd(cmd)
          in ImageCmd   then image_cmd(cmd)
          in Mesh3DCmd  then # no-op: 3D content has no CPU path (yet)
          in NoopCmd    then # reserved index, paints nothing
          end
        end
      end

      def to_png : Bytes
        PNG.encode_rgba(@pixels, @width, @height)
      end

      # -- primitive sinks ---------------------------------------------------

      # Blend one pixel (straight-alpha src-over), multiplied by an
      # antialiasing coverage in 0..1. `corners` (when set) rounds the
      # clip's corners: the pixel must be inside the clip rect AND —
      # inside a corner square — inside the corner arc (the per-pixel
      # half of the engine's rounded subtree clip; only pixels in a
      # corner square pay the distance test).
      def blend_px(x : Int32, y : Int32, c : Color32, cov : Float64,
                   clip : Rect? = nil, replace : Bool = false,
                   corners : CornerRadii? = nil) : Nil
        return unless cov > 0.0
        if clip
          px = x + 0.5
          py = y + 0.5
          return unless px >= clip.min.x && px < clip.max.x &&
                        py >= clip.min.y && py < clip.max.y
          if corners && !rounded_clip_contains?(px, py, clip, corners)
            return
          end
        end
        a = c.a.to_f64 * cov
        return if a <= 0.0
        i = (y * @width + x) * 4
        if replace
          # OVERWRITE dst rgb AND alpha (Painter#rect_replace semantics).
          @pixels[i] = c.r
          @pixels[i + 1] = c.g
          @pixels[i + 2] = c.b
          @pixels[i + 3] = a.round.clamp(0.0, 255.0).to_u8
          return
        end
        sa = a / 255.0
        da = @pixels[i + 3].to_f64 / 255.0
        out_a = sa + da * (1.0 - sa)
        return if out_a <= 0.0
        k = sa / out_a # src weight in the straight-alpha mix
        @pixels[i] = blend_channel(c.r, @pixels[i], k)
        @pixels[i + 1] = blend_channel(c.g, @pixels[i + 1], k)
        @pixels[i + 2] = blend_channel(c.b, @pixels[i + 2], k)
        @pixels[i + 3] = (out_a * 255.0).round.clamp(0.0, 255.0).to_u8
      end

      private def blend_channel(src : UInt8, dst : UInt8, k : Float64) : UInt8
        (src.to_f64 * k + dst.to_f64 * (1.0 - k))
          .round.clamp(0.0, 255.0).to_u8
      end

      # Is the point inside `clip` rounded by `corners`? The rect part
      # is already tested by the caller; here only the four corner
      # squares matter — outside them the shape is the plain rect.
      # Pixel-exact fast path: no SDF, one squared-distance compare in
      # the corner square the point falls into.
      def rounded_clip_contains?(px : Float64, py : Float64, clip : Rect,
                                 corners : CornerRadii) : Bool
        lim = {clip.width, clip.height}.min / 2.0
        tl = {corners.top_left, lim}.min
        tr = {corners.top_right, lim}.min
        br = {corners.bottom_right, lim}.min
        bl = {corners.bottom_left, lim}.min
        if px < clip.min.x + tl && py < clip.min.y + tl
          dx = px - (clip.min.x + tl)
          dy = py - (clip.min.y + tl)
          return dx * dx + dy * dy <= tl * tl
        end
        if px > clip.max.x - tr && py < clip.min.y + tr
          dx = px - (clip.max.x - tr)
          dy = py - (clip.min.y + tr)
          return dx * dx + dy * dy <= tr * tr
        end
        if px > clip.max.x - br && py > clip.max.y - br
          dx = px - (clip.max.x - br)
          dy = py - (clip.max.y - br)
          return dx * dx + dy * dy <= br * br
        end
        if px < clip.min.x + bl && py > clip.max.y - bl
          dx = px - (clip.min.x + bl)
          dy = py - (clip.max.y - bl)
          return dx * dx + dy * dy <= bl * bl
        end
        true
      end

      private def text_cmd(cmd : TextCmd) : Nil
        if renderer = @@text_renderer
          renderer.call(cmd, self)
        else
          placeholder_text(cmd)
        end
      end

      # No real font backend installed: draw the text's extent as an
      # outlined box so layout is still visible in the shot.
      private def placeholder_text(cmd : TextCmd) : Nil
        w = cmd.text.size * cmd.size * 0.6
        box = Rect.from_min_size(cmd.pos, Vec2.new(w, cmd.size))
        r = clip_bounds(box, cmd.clip)
        return if r.width <= 0 || r.height <= 0
        (r.top.to_i..r.bottom.to_i).each do |y|
          (r.left.to_i..r.right.to_i).each do |x|
            edge = (y - r.top < 1) || (r.bottom - y <= 1) ||
                   (x - r.left < 1) || (r.right - x <= 1)
            blend_px(x, y, cmd.color, edge ? 0.8 : 0.12, cmd.clip, corners: cmd.clip_corners)
          end
        end
      end

      private def rect_cmd(cmd : RectCmd) : Nil
        # The standard border algorithm: a bordered background paints
        # as the overlay of nested fills (`.border_overlay_layers`) —
        # outer border plate(s) + the inset background — straight
        # through the plain fill path below. Stroke-only rects (no
        # background under the border) keep the stroke band code.
        if (overlay = Egui.border_overlay_layers(cmd))
          overlay.each { |sub| rect_cmd(sub) }
          return
        end
        return if cmd.fill.nil? && cmd.stroke_color.nil? && cmd.gradient.nil?
        r = cmd.rect
        x0 = {(r.left - 2).floor.to_i, 0}.max
        y0 = {(r.top - 2).floor.to_i, 0}.max
        x1 = {(r.right + 2).ceil.to_i, @width}.min
        y1 = {(r.bottom + 2).ceil.to_i, @height}.min
        rounding = cmd.rounding.clamp(0.0, {r.width, r.height}.min / 2.0)

        (y0...y1).each do |y|
          py = y + 0.5
          (x0...x1).each do |x|
            px = x + 0.5
            # Per-corner rounding (CSS `border-radius: a b c d`) drives
            # both the FILL and the stroke band; the uniform
            # `rounding` stays the fallback (and the per-side border
            # path's corner radius).
            d = if (cs = cmd.corners)
              sd_rounded_corners(px, py, r, cs)
            else
              sd_rounded_rect(px, py, r, rounding)
            end
            if (grad = cmd.gradient) || (fill = cmd.fill) || (g2 = cmd.fill2)
              cov = cov_from_sdf(d)
              if cov > 0.0
                c = if (grad = cmd.gradient)
                  # background-gradient: exact per-pixel evaluation —
                  # the CPU path is the reference the GPU approximates.
                  grad.color_at(px, py, r)
                else
                  base = fill || cmd.fill2.not_nil!
                  if (g2 = cmd.fill2) && fill
                    t = r.height > 0 ? ((py - r.top) / r.height).clamp(0.0, 1.0) : 0.0
                    base = lerp_color(fill, g2, t)
                  end
                  base
                end
                blend_px(x, y, c, cov, cmd.clip, cmd.replace?, cmd.clip_corners)
              end
            end
            if (sides = cmd.stroke_sides)
              # Per-side borders on a stroke-only rect (no background
              # under the border): each side contributes its own
              # geometry (a shortened edge segment, plus a corner arc
              # where both adjacent sides are on — the join takes the
              # wider side's width/color); the nearest one wins the
              # pixel. The CPU mirror of sokol's per-side bars + corner
              # rings. Bordered backgrounds take the overlay path above.
              if (band = side_band(px, py, r, rounding, sides))
                blend_px(x, y, band[:side].color,
                  band_cov(band[:d], band[:side].width), cmd.clip,
                  corners: cmd.clip_corners)
              end
            elsif (sc = cmd.stroke_color) && cmd.stroke_width > 0.0
              # Band INSIDE the outline (the CSS two-rect model: the
              # border lives between the outer edge and the deflated
              # background rect) — d + w/2 shifts band_cov's centered
              # window [-w/2, w/2] to the inside window [-w, 0],
              # matching sokol's edge-inward bars.
              w = cmd.stroke_width
              band = band_cov(d + w / 2.0, w)
              blend_px(x, y, sc, band, cmd.clip, corners: cmd.clip_corners) if band > 0.0
            end
          end
        end
      end

      # The nearest per-side border geometry under (px, py), mirroring
      # the CSS two-rect model as tessellated by sokol: every ON side
      # offers its straight band sitting INSIDE the edge (centerline
      # edge + w/2, shortened by the corner radius), every corner
      # touched by at least one on side offers its ring band
      # [rad - w, rad] (the join takes the wider side's width/color).
      # Returns {d, side} — the caller bands with that side's width —
      # or nil when no side is on at all.
      private def side_band(px : Float64, py : Float64, r : Rect, rad : Float64,
                            sides : Egui::StrokeSides) : NamedTuple(d: Float64, side: Egui::SideStroke)?
        cands = [] of {Float64, Egui::SideStroke}
        if sides.top.on?
          y = r.top + sides.top.width / 2.0
          cands << {sd_segment(px, py, Pos2.new(r.left + rad, y),
            Pos2.new(r.right - rad, y)), sides.top}
        end
        if sides.bottom.on?
          y = r.bottom - sides.bottom.width / 2.0
          cands << {sd_segment(px, py, Pos2.new(r.left + rad, y),
            Pos2.new(r.right - rad, y)), sides.bottom}
        end
        if sides.left.on?
          x = r.left + sides.left.width / 2.0
          cands << {sd_segment(px, py, Pos2.new(x, r.top + rad),
            Pos2.new(x, r.bottom - rad)), sides.left}
        end
        if sides.right.on?
          x = r.right - sides.right.width / 2.0
          cands << {sd_segment(px, py, Pos2.new(x, r.top + rad),
            Pos2.new(x, r.bottom - rad)), sides.right}
        end
        return nil if cands.empty?
        if rad > 0.0
          corners = {
            {sides.top, sides.left, r.left + rad, r.top + rad},
            {sides.top, sides.right, r.right - rad, r.top + rad},
            {sides.bottom, sides.right, r.right - rad, r.bottom - rad},
            {sides.bottom, sides.left, r.left + rad, r.bottom - rad},
          }
          corners.each do |a, b, ccx, ccy|
            j = Egui::StrokeSides.wider(a, b)
            next unless j.on?
            # ring band [rad - w, rad]: centerline at rad - w/2
            arc = Math.sqrt((px - ccx) ** 2 + (py - ccy) ** 2) -
                  (rad - j.width / 2.0)
            cands << {arc.abs, j}
          end
        end
        best = cands.min_by { |(d, _)| d }
        {d: best[0], side: best[1]}
      end

      private def circle_cmd(cmd : CircleCmd) : Nil
        x0 = {(cmd.center.x - cmd.radius - 2).floor.to_i, 0}.max
        y0 = {(cmd.center.y - cmd.radius - 2).floor.to_i, 0}.max
        x1 = {(cmd.center.x + cmd.radius + 2).ceil.to_i, @width}.min
        y1 = {(cmd.center.y + cmd.radius + 2).ceil.to_i, @height}.min
        (y0...y1).each do |y|
          py = y + 0.5
          (x0...x1).each do |x|
            px = x + 0.5
            d = Math.sqrt((px - cmd.center.x) ** 2 + (py - cmd.center.y) ** 2) -
                cmd.radius
            if (fill = cmd.fill)
              cov = cov_from_sdf(d)
              blend_px(x, y, fill, cov, cmd.clip, corners: cmd.clip_corners) if cov > 0.0
            end
            if (sc = cmd.stroke) && cmd.stroke_width > 0.0
              band = band_cov(d, cmd.stroke_width)
              blend_px(x, y, sc, band, cmd.clip, corners: cmd.clip_corners) if band > 0.0
            end
          end
        end
      end

      private def line_cmd(cmd : LineCmd) : Nil
        half = cmd.width / 2.0
        lo_x = {cmd.p1.x, cmd.p2.x}.min
        lo_y = {cmd.p1.y, cmd.p2.y}.min
        hi_x = {cmd.p1.x, cmd.p2.x}.max
        hi_y = {cmd.p1.y, cmd.p2.y}.max
        x0 = {(lo_x - half - 1).floor.to_i, 0}.max
        y0 = {(lo_y - half - 1).floor.to_i, 0}.max
        x1 = {(hi_x + half + 1).ceil.to_i, @width}.min
        y1 = {(hi_y + half + 1).ceil.to_i, @height}.min
        (y0...y1).each do |y|
          py = y + 0.5
          (x0...x1).each do |x|
            px = x + 0.5
            cov = cov_from_sdf(sd_segment(px, py, cmd.p1, cmd.p2) - half)
            blend_px(x, y, cmd.color, cov, cmd.clip, corners: cmd.clip_corners) if cov > 0.0
          end
        end
      end

      private def tri_cmd(cmd : TriCmd) : Nil
        xs = {cmd.a.x, cmd.b.x, cmd.c.x}
        ys = {cmd.a.y, cmd.b.y, cmd.c.y}
        x0 = {xs.min.floor.to_i, 0}.max
        y0 = {ys.min.floor.to_i, 0}.max
        x1 = {xs.max.ceil.to_i, @width}.min
        y1 = {ys.max.ceil.to_i, @height}.min
        (y0...y1).each do |y|
          py = y + 0.5
          (x0...x1).each do |x|
            px = x + 0.5
            d = sd_triangle(px, py, cmd.a, cmd.b, cmd.c)
            cov = cov_from_sdf(d)
            blend_px(x, y, cmd.fill, cov, cmd.clip, corners: cmd.clip_corners) if cov > 0.0
          end
        end
      end

      private def arc_cmd(cmd : ArcCmd) : Nil
        half = cmd.width / 2.0
        reach = cmd.radius + half + 1.0
        x0 = {(cmd.center.x - reach).floor.to_i, 0}.max
        y0 = {(cmd.center.y - reach).floor.to_i, 0}.max
        x1 = {(cmd.center.x + reach).ceil.to_i, @width}.min
        y1 = {(cmd.center.y + reach).ceil.to_i, @height}.min
        a0 = {cmd.start_angle, cmd.end_angle}.min
        a1 = {cmd.start_angle, cmd.end_angle}.max
        (y0...y1).each do |y|
          py = y + 0.5
          (x0...x1).each do |x|
            px = x + 0.5
            dx = px - cmd.center.x
            dy = py - cmd.center.y
            dist = Math.sqrt(dx * dx + dy * dy)
            ring = cov_from_sdf(half - (dist - cmd.radius).abs)
            ang = Math.atan2(dy, dx)
            in_arc = a1 - a0 >= 2 * Math::PI ||
                     (ang >= a0 && ang <= a1)
            cov = in_arc ? ring : 0.0
            blend_px(x, y, cmd.color, cov, cmd.clip, corners: cmd.clip_corners) if cov > 0.0
          end
        end
      end

      # Box-shadow approximation: an alpha falloff from the
      # (spread-inflated, offset-shifted) caster contour — outset rides
      # the same centered gaussian as the GL backends (see
        # driver/sokol.cr #shadow_stop), inset a smooth inward ramp.
      private def shadow_cmd(cmd : ShadowCmd) : Nil
        caster = Rect.from_min_size(
          Pos2.new(cmd.rect.min.x + cmd.offset.x - cmd.spread,
            cmd.rect.min.y + cmd.offset.y - cmd.spread),
          Vec2.new(cmd.rect.width + 2 * cmd.spread,
            cmd.rect.height + 2 * cmd.spread))
        reach = cmd.blur + cmd.spread + 2.0
        x0 = {(caster.left - reach).floor.to_i, 0}.max
        y0 = {(caster.top - reach).floor.to_i, 0}.max
        x1 = {(caster.right + reach).ceil.to_i, @width}.min
        y1 = {(caster.bottom + reach).ceil.to_i, @height}.min
        rounding = cmd.rounding.clamp(0.0,
          {caster.width, caster.height}.min / 2.0)
        blur = {cmd.blur, 0.5}.max
        reach = blur * 1.5
        rim = Math.exp(-4.5) # exp(-2*(1.5)^2): the tail at d = reach
        (y0...y1).each do |y|
          py = y + 0.5
          (x0...x1).each do |x|
            px = x + 0.5
            d = sd_rounded_rect(px, py, caster, rounding)
            t = if cmd.inset?
                  # fade INWARD from the widget's own edge; the wall
                  # coverage is HALF the color alpha (gaussian centered
                  # on the wall — same rule as the outset edge), the
                  # reach grows with the offset's push and spread.
                  reach_in = blur * 0.7 + cmd.spread +
                    {cmd.offset.x.abs, cmd.offset.y.abs}.max
                  d >= 0.0 ? 0.0 : (-d / reach_in).clamp(0.0, 1.0)
                else
                  # CSS falloff: the gaussian (sigma = blur/2) is
                  # CENTERED on the caster edge — half the color alpha
                  # just outside, solid inside, 0 at 1.5*blur.
                  (1.0 - d / reach).clamp(0.0, 1.0)
                end
            cov = if cmd.inset?
                    0.5 * (Math.exp(-2.0 * t * t) - Math.exp(-2.0)) /
                      (1.0 - Math.exp(-2.0))
                  elsif d <= 0.0
                    1.0
                  else
                    0.5 * (Math.exp(-4.5 * t * t) - rim) / (1.0 - rim)
                  end
            blend_px(x, y, cmd.color, cov * cmd.color.a.to_f64 / 255.0,
              cmd.clip, corners: cmd.clip_corners) if cov > 0.0
          end
        end
      end

      private def image_cmd(cmd : ImageCmd) : Nil
        if (hook = self.class.image_renderer)
          hook.call(cmd, self)
        else
          placeholder_image(cmd)
        end
      end

      # The no-texture fallback: a light checker under the tint marks
      # the image spot. Public only for capybara/images.cr's fallback
      # path — not part of the Raster API.
      def placeholder_image(cmd : ImageCmd) : Nil
        r = cmd.rect
        (r.top.to_i...r.bottom.to_i).each do |y|
          (r.left.to_i...r.right.to_i).each do |x|
            # placeholder: a light checker under the tint marks the
            # image spot when no pixels are available
            checker = ((x // 8) + (y // 8)).even?
            base = checker ? 45.0 : 70.0
            c = Color32.rgba(
              (cmd.tint.r.to_f64 * base / 255.0).to_i,
              (cmd.tint.g.to_f64 * base / 255.0).to_i,
              (cmd.tint.b.to_f64 * base / 255.0).to_i, 255)
            blend_px(x, y, c, 1.0, cmd.clip, corners: cmd.clip_corners)
          end
        end
      end

      # -- geometry helpers --------------------------------------------------

      # A paintable rect: the shape intersected with its clip and the
      # framebuffer bounds (integer pixel range).
      private def clip_bounds(r : Rect, clip : Rect?) : Rect
        c = clip || Rect.infinite
        Rect.new(
          Pos2.new({r.min.x, c.min.x, 0.0}.max,
            {r.min.y, c.min.y, 0.0}.max),
          Pos2.new({r.max.x, c.max.x, @width.to_f64}.min,
            {r.max.y, c.max.y, @height.to_f64}.min))
      end

      # Signed distance to a rounded-rect contour, negative inside.
      private def sd_rounded_rect(px : Float64, py : Float64, r : Rect,                                  rad : Float64) : Float64
        cx = (r.min.x + r.max.x) / 2.0
        cy = (r.min.y + r.max.y) / 2.0
        hx = (r.max.x - r.min.x) / 2.0
        hy = (r.max.y - r.min.y) / 2.0
        dx = (px - cx).abs - (hx - rad)
        dy = (py - cy).abs - (hy - rad)
        ax = dx > 0 ? dx : 0.0
        ay = dy > 0 ? dy : 0.0
        outside = Math.sqrt(ax * ax + ay * ay)
        inside = {dx, dy}.max
        outside + (inside < 0.0 ? inside : 0.0) - rad
      end

      # Signed distance to a rect whose corners each carry their own
      # radius (CSS `border-radius: a b c d`): min over the four
      # shortened edge segments and four quarter arcs, signed by
      # point-in-shape (inside the sharp rect AND inside each corner
      # arc's square).
      private def sd_rounded_corners(px : Float64, py : Float64, r : Rect,
                                     c : CornerRadii) : Float64
        lim = {r.width, r.height}.min / 2.0
        tl = {c.top_left, lim}.min
        tr = {c.top_right, lim}.min
        br = {c.bottom_right, lim}.min
        bl = {c.bottom_left, lim}.min
        inf = 1e9
        arc = ->(ccx : Float64, ccy : Float64, rad : Float64,
                 in_sq : Bool) do
          if in_sq && rad > 0.0
            dx = px - ccx
            dy = py - ccy
            (Math.sqrt(dx * dx + dy * dy) - rad).abs
          else
            inf
          end
        end
        best = {
          sd_segment(px, py, Pos2.new(r.left + tl, r.top),
            Pos2.new(r.right - tr, r.top)),
          sd_segment(px, py, Pos2.new(r.left + bl, r.bottom),
            Pos2.new(r.right - br, r.bottom)),
          sd_segment(px, py, Pos2.new(r.left, r.top + tl),
            Pos2.new(r.left, r.bottom - bl)),
          sd_segment(px, py, Pos2.new(r.right, r.top + tr),
            Pos2.new(r.right, r.bottom - br)),
          arc.call(r.left + tl, r.top + tl, tl,
            px < r.left + tl && py < r.top + tl),
          arc.call(r.right - tr, r.top + tr, tr,
            px > r.right - tr && py < r.top + tr),
          arc.call(r.right - br, r.bottom - br, br,
            px > r.right - br && py > r.bottom - br),
          arc.call(r.left + bl, r.bottom - bl, bl,
            px < r.left + bl && py > r.bottom - bl),
        }.min
        inside = px > r.left && px < r.right && py > r.top && py < r.bottom
        if inside
          in_arc = ->(ccx : Float64, ccy : Float64, rad : Float64,
                      in_sq : Bool) do
            if in_sq
              (px - ccx) ** 2 + (py - ccy) ** 2 <= rad * rad
            else
              true
            end
          end
          inside = in_arc.call(r.left + tl, r.top + tl, tl,
            px < r.left + tl && py < r.top + tl) &&
                   in_arc.call(r.right - tr, r.top + tr, tr,
            px > r.right - tr && py < r.top + tr) &&
                   in_arc.call(r.right - br, r.bottom - br, br,
            px > r.right - br && py > r.bottom - br) &&
                   in_arc.call(r.left + bl, r.bottom - bl, bl,
            px < r.left + bl && py > r.bottom - bl)
        end
        inside ? -best : best
      end

      # Signed distance to a segment.
      private def sd_segment(px : Float64, py : Float64, a : Pos2,
                             b : Pos2) : Float64
        abx = b.x - a.x
        aby = b.y - a.y
        apx = px - a.x
        apy = py - a.y
        len_sq = abx * abx + aby * aby
        t = len_sq > 0.0 ? ((apx * abx + apy * aby) / len_sq).clamp(0.0, 1.0) : 0.0
        dx = apx - abx * t
        dy = apy - aby * t
        Math.sqrt(dx * dx + dy * dy)
      end

      # Signed distance to a triangle contour, negative inside.
      private def sd_triangle(px : Float64, py : Float64, a : Pos2, b : Pos2,
                              c : Pos2) : Float64
        # point-in-triangle via consistent edge signs
        d1 = cross(px, py, a, b)
        d2 = cross(px, py, b, c)
        d3 = cross(px, py, c, a)
        has_neg = d1 < 0 || d2 < 0 || d3 < 0
        has_pos = d1 > 0 || d2 > 0 || d3 > 0
        if has_neg && has_pos
          # outside: nearest edge distance, positive
          d = {sd_segment(px, py, a, b), sd_segment(px, py, b, c),
               sd_segment(px, py, c, a)}.min
          d
        else
          nearest = {sd_segment(px, py, a, b), sd_segment(px, py, b, c),
                     sd_segment(px, py, c, a)}.min
          -nearest
        end
      end

      private def cross(px : Float64, py : Float64, a : Pos2, b : Pos2) : Float64
        (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)
      end

      # 1px-antialiased coverage from an SDF value (negative = inside).
      private def cov_from_sdf(d : Float64) : Float64
        return 0.0 if d >= 0.5
        return 1.0 if d <= -0.5
        0.5 - d
      end

      # Coverage of a `width`-wide band centered on an SDF zero set.
      private def band_cov(d : Float64, width : Float64) : Float64
        cov_from_sdf((d.abs - width / 2.0))
      end

      private def lerp_color(a : Color32, b : Color32, t : Float64) : Color32
        # Int32 math: channel deltas go BOTH ways and UInt8 - UInt8
        # underflows on a descending gradient.
        Color32.rgba(
          (a.r.to_i32 + (b.r.to_i32 - a.r.to_i32) * t).round.to_i,
          (a.g.to_i32 + (b.g.to_i32 - a.g.to_i32) * t).round.to_i,
          (a.b.to_i32 + (b.b.to_i32 - a.b.to_i32) * t).round.to_i,
          (a.a.to_i32 + (b.a.to_i32 - a.a.to_i32) * t).round.to_i)
      end

      private def fill_rect_color(c : Color32) : Nil
        @height.times do |y|
          row = y * @width * 4
          @width.times do |x|
            i = row + x * 4
            @pixels[i] = c.r
            @pixels[i + 1] = c.g
            @pixels[i + 2] = c.b
            @pixels[i + 3] = c.a
          end
        end
      end
    end
  end
end
