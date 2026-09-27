# A small built-in vector icon set for button icons
# (`Button#icon(:check)` etc.), drawn with the phase-0 painter
# primitives. Raster-image icons come with textures (phase 6).

module Egui
  module Icons
    NAMES = {:check, :close, :left, :right, :up, :down, :plus, :minus,
             :copy, :paste, :trash}

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
        painter.line(rect.min, rect.max, width, color)
        painter.line(Pos2.new(rect.max.x, rect.min.y),
          Pos2.new(rect.min.x, rect.max.y), width, color)
      when :left
        tip = rect.min + Egui::Vec2.new(0.0, rect.height / 2.0)
        painter.line(Pos2.new(rect.right, rect.min.y), tip, width, color)
        painter.line(tip, Pos2.new(rect.right, rect.max.y), width, color)
      when :right
        tip = Pos2.new(rect.max.x, rect.center.y)
        painter.line(Pos2.new(rect.left, rect.min.y), tip, width, color)
        painter.line(tip, Pos2.new(rect.left, rect.max.y), width, color)
      when :up
        tip = Pos2.new(rect.center.x, rect.min.y)
        painter.line(Pos2.new(rect.min.x, rect.max.y), tip, width, color)
        painter.line(tip, Pos2.new(rect.max.x, rect.max.y), width, color)
      when :down
        tip = Pos2.new(rect.center.x, rect.max.y)
        painter.line(Pos2.new(rect.min.x, rect.min.y), tip, width, color)
        painter.line(tip, Pos2.new(rect.max.x, rect.min.y), width, color)
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
