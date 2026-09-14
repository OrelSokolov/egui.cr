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

    # egui `ui.checkbox(&mut bool, text)` — Crystal keeps the value in
    # app state; the block fires with the new value on toggle, and
    # `Response#changed?` reports the same on the returned Response.
    def checkbox(checked : Bool, text : String, &on_change : Bool ->) : Response
      response = add(Checkbox.new(checked, text))
      on_change.call(!checked) if response.changed?
      response
    end

    def checkbox(checked : Bool, text : String) : Response
      add(Checkbox.new(checked, text))
    end

    # egui `ui.radio(selected, text)`.
    def radio(selected : Bool, text : String) : Response
      add(RadioButton.new(selected, text))
    end

    # egui `ui.radio_value(&mut value, new_value, text)`.
    def radio_value(selected : Bool, value : Bool, text : String,
                    &on_select : Bool ->) : Response
      response = add(RadioButton.new(selected, text))
      on_select.call(value) if response.changed?
      response
    end

    def separator : Response
      add(Separator.new)
    end

    def progress_bar(fraction : Float64, text : String? = nil,
                     animate : Bool = false) : Response
      add(ProgressBar.new(fraction, text: text, animate: animate))
    end

    def spinner(size : Float64? = nil) : Response
      add(Spinner.new(size))
    end

    # egui `ui.hyperlink(url)` / `ui.hyperlink_to(label, url)`.
    # egui `ui.add_enabled`-style block helpers for value widgets:
    # the block fires with the new value when it changed this frame.
    def slider(value : Float64, range : Range(Float64, Float64),
               text : String? = nil, &on_change : Float64 ->) : Response
      response = add(Slider.new(value, range, text))
      if response.changed? && (v = response.widget_value)
        on_change.call(v)
      end
      response
    end

    def drag_value(value : Float64, speed : Float64 = 1.0,
                   prefix : String = "", suffix : String = "",
                   &on_change : Float64 ->) : Response
      response = add(DragValue.new(value, speed, prefix, suffix))
      if response.changed? && (v = response.widget_value)
        on_change.call(v)
      end
      response
    end

    def combo_box(id : String, selected : String, options : Array(String),
                  width : Float64 = 160.0, &on_select : String ->) : Bool
      ComboBox.new(id, selected, options, width).show(self) { |opt| on_select.call(opt) }
    end

    def hyperlink(url : String) : Response
      add(Hyperlink.new(url, url))
    end

    def hyperlink_to(label : String, url : String) : Response
      add(Hyperlink.new(label, url))
    end

    # egui `Ui::available_size` — how much room is left in this region
    # (from the cursor to max_rect's far corner in layout direction).
    def available_size : Vec2
      if @layout.horizontal?
        Vec2.new({@max_rect.right - @cursor.x, 0.0}.max, @max_rect.bottom - @cursor.y)
      else
        Vec2.new(@max_rect.right - @cursor.x, @max_rect.bottom - @cursor.y)
      end
    end

    def available_width : Float64
      {@max_rect.right - @cursor.x, 0.0}.max
    end

    def available_height : Float64
      {@max_rect.bottom - @cursor.y, 0.0}.max
    end

    # egui `Frame::show` — a padded, painted panel around a block of
    # contents. Reserve a paint slot, lay the children out inside the
    # margin, then back-paint the frame under them (the #window trick).
    def frame(fill : Color32? = nil, stroke : Color32? = nil,
              rounding : Float64 = 6.0, margin : Vec2? = nil,
              stroke_width : Float64 = 1.0, &block : Ui ->) : Rect
      m = margin || style.spacing.window_padding
      bg_index = painter.add_noop

      inner = Rect.from_min_size(
        @cursor + m,
        Vec2.new({@max_rect.right - @cursor.x - 2 * m.x, 0.0}.max, 1e6))
      child = child_ui(inner)
      yield child

      outer = Rect.new(child.min_rect.min - m, child.min_rect.max + m)
      outer = Rect.new(
        Pos2.new({outer.min.x, @cursor.x}.min, {outer.min.y, @cursor.y}.min),
        Pos2.new({outer.max.x, @max_rect.right}.max, outer.max.y))
      min_rect = @min_rect.union(outer)
      @cursor = @layout.advance(@cursor, outer.size,
        style.spacing.item_spacing)
      @min_rect = min_rect

      if fill || stroke
        painter.set(bg_index,
          RectCmd.new(painter.clip, outer, rounding, fill, stroke, stroke_width))
      end
      outer
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
