# A small built-in vector icon set for button icons
# (`Button#icon(:check)` etc.), drawn with the phase-0 painter
# primitives. Raster-image icons come with textures (phase 6).

module Egui
  module Icons
    NAMES = {:check, :close, :left, :right, :up, :down, :plus, :minus}

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
      end
    end
  end
end
