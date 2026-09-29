# A small built-in vector icon set for button icons
# (`Button#icon(:check)` etc.), drawn with the phase-0 painter
# primitives. Raster-image icons come with textures (phase 6).
#
# The direction glyphs (:left/:right/:up/:down) and :close are
# Lucide icons (`icons/lucide/*.svg`, ISC): the 24×24 path points
# are aspect-fitted into the target rect and stroked with round
# caps/joins like the source set (#polyline24).

module Egui
  module Icons
    NAMES = {:check, :close, :left, :right, :up, :down, :plus, :minus,
             :copy, :paste, :trash, :download}

    # Draw `name` fitted into `rect` with `color` and stroke width.
    def self.draw(painter : Painter, name : Symbol, rect : Rect,
                  color : Color32, width : Float64 = 2.0) : Nil
      case name
      when :check
        a = Pos2.new(rect.left + 0.22 * rect.width, rect.top + 0.55 * rect.height)
        b = Pos2.new(rect.left + 0.44 * rect.width, rect.top + 0.75 * rect.height)
        c = Pos2.new(rect.left + 0.80 * rect.width, rect.top + 0.28 * rect.height)
        painter.line(a, b, width, color)
        painter.line(b, c, width, color)
      when :close
        # Lucide x (`icons/lucide/x.svg`: M18 6 6 18 / m6 6 12 12): the
        # diagonals span the 12×12 box centered in the icon's 24-grid —
        # inset a quarter-box from every edge. That inset is the fix
        # for the overflowing X: corner-to-corner diagonals push the
        # stroke quads (±width/2 perpendicular) OUTSIDE the icon rect,
        # so the glyph spilled past its button cell into the clip. The
        # stroke weight is grid-true — `width` reads as the Lucide
        # stroke-width at a 24px box (2.0 default), floored at 1px so
        # small tab markers stay visible — and the endpoint dots
        # emulate the set's round caps.
        fit = {rect.width, rect.height}.min / 12.0
        w = {width * fit / 2.0, 1.0}.max
        d = 6.0 * fit
        c = rect.center
        pts = {Pos2.new(c.x - d, c.y - d), Pos2.new(c.x + d, c.y + d),
               Pos2.new(c.x - d, c.y + d), Pos2.new(c.x + d, c.y - d)}
        painter.line(pts[0], pts[1], w, color)
        painter.line(pts[2], pts[3], w, color)
        r = w / 2.0
        pts.each { |p| painter.circle_filled(p, r, color) }
      when :left
        # Lucide chevron-left: m15 18-6-6 6-6
        chevron(painter, rect, width, color,
          Vec2.new(15.0, 18.0), Vec2.new(9.0, 12.0), Vec2.new(15.0, 6.0))
      when :right
        # Lucide chevron-right: m9 18 6-6-6-6
        chevron(painter, rect, width, color,
          Vec2.new(9.0, 18.0), Vec2.new(15.0, 12.0), Vec2.new(9.0, 6.0))
      when :up
        # Lucide chevron-up: m18 15-6-6-6 6
        chevron(painter, rect, width, color,
          Vec2.new(18.0, 15.0), Vec2.new(12.0, 9.0), Vec2.new(6.0, 15.0))
      when :down
        # Lucide chevron-down: m6 9 6 6 6-6
        chevron(painter, rect, width, color,
          Vec2.new(6.0, 9.0), Vec2.new(12.0, 15.0), Vec2.new(18.0, 9.0))
      when :download
        # An arrow pointing down into a tray (export/save-as glyph).
        cx = rect.center.x
        painter.line(Pos2.new(cx, rect.top),
          Pos2.new(cx, rect.top + 0.55 * rect.height), width, color)
        painter.line(Pos2.new(rect.left + 0.26 * rect.width,
          rect.top + 0.32 * rect.height),
          Pos2.new(cx, rect.top + 0.60 * rect.height), width, color)
        painter.line(Pos2.new(rect.right - 0.26 * rect.width,
          rect.top + 0.32 * rect.height),
          Pos2.new(cx, rect.top + 0.60 * rect.height), width, color)
        painter.line(Pos2.new(rect.left + 0.12 * rect.width,
          rect.top + 0.84 * rect.height),
          Pos2.new(rect.right - 0.12 * rect.width,
            rect.top + 0.84 * rect.height), width, color)
        painter.line(Pos2.new(rect.left + 0.12 * rect.width,
          rect.top + 0.64 * rect.height),
          Pos2.new(rect.left + 0.12 * rect.width,
            rect.top + 0.84 * rect.height), width, color)
        painter.line(Pos2.new(rect.right - 0.12 * rect.width,
          rect.top + 0.64 * rect.height),
          Pos2.new(rect.right - 0.12 * rect.width,
            rect.top + 0.84 * rect.height), width, color)
      when :plus
        cx, cy = rect.center.x, rect.center.y
        painter.line(Pos2.new(cx, rect.top), Pos2.new(cx, rect.bottom), width, color)
        painter.line(Pos2.new(rect.left, cy), Pos2.new(rect.right, cy), width, color)
      when :minus
        cy = rect.center.y
        painter.line(Pos2.new(rect.left, cy), Pos2.new(rect.right, cy), width, color)
      when :copy
        # Two overlapping document outlines (front sheet partly covers
        # the back one).
        back = Rect.from_min_size(
          Pos2.new(rect.left + 0.05 * rect.width, rect.top + 0.20 * rect.height),
          Vec2.new(0.60 * rect.width, 0.75 * rect.height))
        front = Rect.from_min_size(
          Pos2.new(rect.left + 0.35 * rect.width, rect.top + 0.05 * rect.height),
          Vec2.new(0.60 * rect.width, 0.75 * rect.height))
        painter.rect(back, 1.0, nil, color, width)
        painter.rect(front, 1.0, nil, color, width)
      when :paste
        # A clipboard: board outline with a tab on the top edge.
        board = Rect.from_min_size(
          Pos2.new(rect.left + 0.15 * rect.width, rect.top + 0.15 * rect.height),
          Vec2.new(0.70 * rect.width, 0.80 * rect.height))
        painter.rect(board, 1.0, nil, color, width)
        painter.rect(Rect.from_min_size(
          Pos2.new(rect.left + 0.35 * rect.width, rect.top),
          Vec2.new(0.30 * rect.width, 0.20 * rect.height)), 1.0, nil, color, width)
      when :trash
        # A trash can: lid with a handle plus the body outline.
        lid_y = rect.top + 0.25 * rect.height
        painter.line(Pos2.new(rect.left + 0.10 * rect.width, lid_y),
          Pos2.new(rect.right - 0.10 * rect.width, lid_y), width, color)
        painter.line(Pos2.new(rect.center.x - 0.15 * rect.width, rect.top + 0.05 * rect.height),
          Pos2.new(rect.center.x + 0.15 * rect.width, rect.top + 0.05 * rect.height), width, color)
        painter.line(Pos2.new(rect.center.x, rect.top + 0.05 * rect.height),
          Pos2.new(rect.center.x, lid_y), width, color)
        painter.rect(Rect.from_min_size(
          Pos2.new(rect.left + 0.20 * rect.width, lid_y),
          Vec2.new(0.60 * rect.width, 0.70 * rect.height)), 1.0, nil, color, width)
      end
    end

    # Stroke a Lucide polyline: `points` are the icon's path points on
    # its 24×24 grid. The glyph's bounding box is aspect-fitted into
    # `rect` (centered, like `Svg#paint` fits a viewBox) and `width`
    # scales with the fit — it is the Lucide stroke-width (2.0 = the
    # set's default), not screen pixels. The dots on the points
    # emulate the set's round caps/joins over the painter's butt-cap
    # segments.
    private def self.polyline24(painter : Painter, rect : Rect,
                               width : Float64, color : Color32,
                               points : Array(Vec2)) : Nil
      bx = points.min_of(&.x)
      by = points.min_of(&.y)
      bw = points.max_of(&.x) - bx
      bh = points.max_of(&.y) - by
      scale = {rect.width / bw, rect.height / bh}.min
      ox = rect.left + (rect.width - bw * scale) / 2.0 - bx * scale
      oy = rect.top + (rect.height - bh * scale) / 2.0 - by * scale
      pts = points.map { |p| Pos2.new(ox + p.x * scale, oy + p.y * scale) }
      w = width * scale
      (1...pts.size).each do |i|
        painter.line(pts[i - 1], pts[i], w, color)
      end
      r = w / 2.0
      pts.each { |p| painter.circle_filled(p, r, color) }
    end

    # Stroke a Lucide chevron: `a`/`b`/`c` are the icon's path points
    # on its 24×24 grid (see #polyline24 for the fit).
    private def self.chevron(painter : Painter, rect : Rect, width : Float64,
                             color : Color32, a : Vec2, b : Vec2,
                             c : Vec2) : Nil
      polyline24(painter, rect, width, color, [a, b, c])
    end

    # Win95/XP bevel: fill plus light top/left and dark bottom/right
    # edges (inverted when pressed). Shared by the classic scrollbar
    # and NumberInput's spin arrows so both render the same native
    # arrow-button look.
    def self.bevel(painter : Painter, rect : Rect, fill : Color32,
                   pressed : Bool) : Nil
      painter.rect(rect, 0.0, fill)
      light = fill.mul_color(pressed ? 0.72 : 1.28)
      dark = fill.mul_color(pressed ? 1.28 : 0.72)
      painter.line(rect.min,
        Pos2.new(rect.right - 1.0, rect.top), 1.0, light)
      painter.line(rect.min,
        Pos2.new(rect.left, rect.bottom - 1.0), 1.0, light)
      painter.line(Pos2.new(rect.right - 1.0, rect.top),
        Pos2.new(rect.right - 1.0, rect.bottom - 1.0), 1.0, dark)
      painter.line(Pos2.new(rect.left, rect.bottom - 1.0),
        Pos2.new(rect.right - 1.0, rect.bottom - 1.0), 1.0, dark)
    end

    # A beveled square button with a centered arrow icon (classic
    # scrollbar arrows, NumberInput spin arrows).
    def self.arrow_button(painter : Painter, name : Symbol, rect : Rect,
                          fill : Color32, arrow : Color32,
                          pressed : Bool) : Nil
      bevel(painter, rect, fill, pressed)
      draw(painter, name, Rect.from_min_size(
        Pos2.new(rect.left + 4.0, rect.top + 4.0),
        Vec2.new(rect.width - 8.0, rect.height - 8.0)), arrow, 2.0)
    end
  end
end
