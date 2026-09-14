# Port of egui_upstream/crates/egui/src/layout.rs — trimmed to the
# two directions slice 1 uses (top_down, left_to_right). The layout
# owns nothing; it is the pure function "advance this cursor by this
# size", which is the part of egui's Layout the cursor logic implements.

module Egui
  class Layout
    enum Dir
      TopDown
      LeftToRight
    end

    getter dir : Dir

    def initialize(@dir : Dir = :top_down)
    end

    def self.top_down : Layout
      new(:top_down)
    end

    def self.left_to_right : Layout
      new(:left_to_right)
    end

    def horizontal? : Bool
      @dir.left_to_right?
    end

    def vertical? : Bool
      @dir.top_down?
    end

    # Where the next widget starts after one of `size` was placed at
    # `cursor` (egui `Layout::advance_cursor` minus the cross-axis parts).
    def advance(cursor : Pos2, size : Vec2, spacing : Vec2) : Pos2
      if horizontal?
        Pos2.new(cursor.x + size.x + spacing.x, cursor.y)
      else
        Pos2.new(cursor.x, cursor.y + size.y + spacing.y)
      end
    end
  end
end
