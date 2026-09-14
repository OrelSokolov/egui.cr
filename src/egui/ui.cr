# Port of egui_upstream/crates/egui/src/ui.rs.
#
# `Ui` is a layout region: a cursor advancing through `max_rect`,
# minting child ids, and handing widgets their rects + `Response`s.
# Everything here mirrors the upstream mechanics kept for slice 1:
# `allocate_at_least` → `interact` → paint → return Response.

module Egui
  class Ui
    getter ctx : Context
    getter id : Id
    getter max_rect : Rect
    getter min_rect : Rect
    getter layout : Layout
    property cursor : Pos2
    # egui `Region::expand_to_include_rect`: containers grow their
    # bounding box to cover child regions laid out manually.
    setter min_rect : Rect
    # Layer widgets created through this Ui belong to (egui WidgetRect's
    # layer_id) — hit-testing and paint order both read it.
    property layer : LayerId

    @child_counter : UInt64 = 0

    def initialize(@ctx : Context, @id : Id, @max_rect : Rect,
                   @layout : Layout = Layout.top_down)
      @cursor = @max_rect.min
      @min_rect = Rect.new(@max_rect.min, @max_rect.min)
      @layer = LayerId.background
    end

    def style : Style
      @ctx.style
    end

    def painter : Painter
      @ctx.painter
    end

    # egui `ui.next_auto_id()`: parent id + incrementing child salt.
    def next_widget_id : Id
      @child_counter += 1
      @id.child(@child_counter)
    end

    # egui `Ui::allocate_at_least`: place a widget of `size` at the
    # cursor, grow `min_rect`, advance the cursor.
    def allocate_space(size : Vec2) : Rect
      rect = Rect.from_min_size(@cursor, size)
      @min_rect = @min_rect.union(rect)
      @cursor = @layout.advance(@cursor, size, style.spacing.item_spacing)
      rect
    end

    def allocate_at_least(size : Vec2) : Rect
      allocate_space(size)
    end

    # egui `Ui::interact` — delegates to Context/Memory.
    def interact(rect : Rect, id : Id, sense : Sense) : Response
      @ctx.interact(id, rect, sense, @layer)
    end

    # egui `Ui::new_child`: a child region with its own cursor/layout.
    # Inherits the parent's layer; `id` may be given (stateful widgets
    # derive a stable body id from their own id).
    def child_ui(max_rect : Rect, id : Id? = nil,
                 layout : Layout = Layout.top_down) : Ui
      child = Ui.new(@ctx, id || next_widget_id, max_rect, layout)
      child.layer = @layer
      child
    end

    # egui `Ui::add(widget)` — the generic Widget entry point.
    def add(widget : Widget) : Response
      widget.ui(self)
    end

    def label(text : String) : Response
      add(Label.new(text))
    end

    def heading(text : String) : Response
      add(Label.new(text, size: style.font_size * 1.25))
    end

    def button(text : String) : Response
      add(Button.new(text))
    end

    # egui `ui.horizontal(|ui| …)`: a child Ui laying out left→right on
    # the rest of the current line; afterwards the parent cursor jumps
    # below the row's bounding box (like upstream's single-row shortcut).
    def horizontal(&block : Ui ->) : self
      row = Ui.new(@ctx, next_widget_id,
        Rect.new(@cursor, Pos2.new(@max_rect.right, @max_rect.bottom)),
        Layout.left_to_right)
      yield row
      @min_rect = @min_rect.union(row.min_rect)
      @cursor = Pos2.new(@max_rect.min.x,
        row.min_rect.bottom + style.spacing.item_spacing.y)
      self
    end
  end
end
