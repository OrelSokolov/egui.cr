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
# Mesh3D is a no-op and textured ImageCmds draw a checker placeholder
# (the headless texture registry carries no pixels). Text goes through a
# pluggable renderer — the core alone only knows metrics stubs, so
# `capybara/fonts.cr` (CrystalFonts + glyph atlas) installs the real one;
# without it text draws as outlined boxes that still show the text's
# extents.

module Egui
  module Capybara
    class Raster
      # Text rasterization hook: `(cmd, raster) -> Nil`. Installed by
      # capybara/fonts.cr (which knows Backend::AtlasFonts); the core
      # keeps no backend types.
      class_property text_renderer : (TextCmd, Raster -> Nil)?

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
      # antialiasing coverage in 0..1.
      def blend_px(x : Int32, y : Int32, c : Color32, cov : Float64,
                   clip : Rect? = nil, replace : Bool = false) : Nil
        return unless cov > 0.0
        if clip && !(x >= clip.min.x && x < clip.max.x &&
                     y >= clip.min.y && y < clip.max.y)
          return
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
            blend_px(x, y, cmd.color, edge ? 0.8 : 0.12, cmd.clip)
          end
        end
      end

      private def rect_cmd(cmd : RectCmd) : Nil
        return if cmd.fill.nil? && cmd.stroke_color.nil?
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
            d = sd_rounded_rect(px, py, r, rounding)
            if (fill = cmd.fill) || (g2 = cmd.fill2)
              cov = cov_from_sdf(d)
              if cov > 0.0
                c = fill || cmd.fill2.not_nil!
                if (g2 = cmd.fill2) && fill
                  t = r.height > 0 ? ((py - r.top) / r.height).clamp(0.0, 1.0) : 0.0
                  c = lerp_color(fill, g2, t)
                end
                blend_px(x, y, c, cov, cmd.clip, cmd.replace?)
              end
            end
            if (sc = cmd.stroke_color) && cmd.stroke_width > 0.0
              band = band_cov(d, cmd.stroke_width)
              blend_px(x, y, sc, band, cmd.clip) if band > 0.0
            end
          end
        end
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
              blend_px(x, y, fill, cov, cmd.clip) if cov > 0.0
            end
            if (sc = cmd.stroke) && cmd.stroke_width > 0.0
              band = band_cov(d, cmd.stroke_width)
              blend_px(x, y, sc, band, cmd.clip) if band > 0.0
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
            blend_px(x, y, cmd.color, cov, cmd.clip) if cov > 0.0
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
            blend_px(x, y, cmd.fill, cov, cmd.clip) if cov > 0.0
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
            blend_px(x, y, cmd.color, cov, cmd.clip) if cov > 0.0
          end
        end
      end

      # Box-shadow approximation: a linear alpha ramp over `blur` from the
      # (spread-inflated, offset-shifted) caster contour — the same shape
        # language the backend builds from Gouraud bands.
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
        (y0...y1).each do |y|
          py = y + 0.5
          (x0...x1).each do |x|
            px = x + 0.5
            d = sd_rounded_rect(px, py, caster, rounding)
            t = if cmd.inset?
                  # fade INWARD from the widget's own edge
                  d >= 0.0 ? 0.0 : (-d / blur).clamp(0.0, 1.0)
                else
                  (1.0 - d / blur).clamp(0.0, 1.0)
                end
            # ease the ramp a touch so the band reads gaussian-ish
            cov = t * t * (3.0 - 2.0 * t)
            blend_px(x, y, cmd.color, cov * cmd.color.a.to_f64 / 255.0,
              cmd.clip) if cov > 0.0
          end
        end
      end

      private def image_cmd(cmd : ImageCmd) : Nil
        r = cmd.rect
        (r.top.to_i...r.bottom.to_i).each do |y|
          (r.left.to_i...r.right.to_i).each do |x|
            # placeholder: a light checker under the tint marks the image
            # spot; headless textures carry no real pixels
            checker = ((x // 8) + (y // 8)).even?
            base = checker ? 45.0 : 70.0
            c = Color32.rgba(
              (cmd.tint.r.to_f64 * base / 255.0).to_i,
              (cmd.tint.g.to_f64 * base / 255.0).to_i,
              (cmd.tint.b.to_f64 * base / 255.0).to_i, 255)
            blend_px(x, y, c, 1.0, cmd.clip)
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
        Color32.rgba(
          (a.r + (b.r - a.r) * t).round.to_i,
          (a.g + (b.g - a.g) * t).round.to_i,
          (a.b + (b.b - a.b) * t).round.to_i,
          (a.a + (b.a - a.a) * t).round.to_i)
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
