# Port of egui_upstream/crates/egui/src/layout.rs — trimmed to the
# directions slice 1 uses (top_down, left_to_right) plus the egui.cr
# bottom_up flow (rendering_direction: :up, dialogue mode). The layout
# owns nothing; it is the pure function "advance this cursor by this
# size", which is the part of egui's Layout the cursor logic implements.

module Egui
  class Layout
    enum Dir
      TopDown
      LeftToRight
      BottomUp
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

    # rendering_direction `:up` (dialogue mode): the cursor starts at
    # the region's BOTTOM edge and marches upward — the first widget
    # sits at the bottom, the next one above it.
    def self.bottom_up : Layout
      new(:bottom_up)
    end

    def horizontal? : Bool
      @dir.left_to_right?
    end

    def vertical? : Bool
      @dir.top_down? || @dir.bottom_up?
    end

    def bottom_up? : Bool
      @dir.bottom_up?
    end

    # Where the next widget starts after one of `size` was placed at
    # `cursor` (egui `Layout::advance_cursor` minus the cross-axis
    # parts — cross-axis centering for horizontal rows lives in
    # `Ui#allocate_space` / `Ui#@row_h`).
    def advance(cursor : Pos2, size : Vec2, spacing : Vec2) : Pos2
      if horizontal?
        Pos2.new(cursor.x + size.x + spacing.x, cursor.y)
      elsif bottom_up?
        Pos2.new(cursor.x, cursor.y - size.y - spacing.y)
      else
        Pos2.new(cursor.x, cursor.y + size.y + spacing.y)
      end
    end
  end
end
