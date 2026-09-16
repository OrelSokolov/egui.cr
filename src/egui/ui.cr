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
    # egui `Ui::clip_rect`: widgets laid out through this Ui are only
    # interactable inside this rect (panels/windows/scroll viewports
    # clip their contents; overflowing parts are painted over).
    property clip : Rect

    @child_counter : UInt64 = 0

    def initialize(@ctx : Context, @id : Id, @max_rect : Rect,
                   @layout : Layout = Layout.top_down)
      @cursor = @max_rect.min
      @min_rect = Rect.new(@max_rect.min, @max_rect.min)
      @layer = LayerId.background
      @clip = Rect.infinite
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
      @ctx.interact(id, rect, sense, @layer, @clip)
    end

    # egui `Ui::new_child`: a child region with its own cursor/layout.
    # Inherits the parent's layer and clip rect; `id` may be given
    # (stateful widgets derive a stable body id from their own id).
    def child_ui(max_rect : Rect, id : Id? = nil,
                 layout : Layout = Layout.top_down) : Ui
      child = Ui.new(@ctx, id || next_widget_id, max_rect, layout)
      child.layer = @layer
      child.clip = @clip
      child
    end

    # egui `Ui::add(widget)` — the generic Widget entry point.
    def add(widget : Widget) : Response
      widget.ui(self)
    end

    # `align` mirrors CSS `text-align` on a block: the label reserves
    # the full row width and paints at :left/:center/:right.
    def label(text : String, wrap : Bool = false, align : Symbol = :left) : Response
      add(Label.new(text, wrap: wrap, align: align))
    end

    # egui `ui.label(RichText)`.
    def rich(text : RichText, wrap : Bool = false, align : Symbol? = nil) : Response
      text.align(align) if align && align != :left
      add(Label.new(text, wrap: wrap))
    end

    def heading(text : String, align : Symbol = :left) : Response
      rich(RichText.new(text).heading(style.font_size), align: align)
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
                   format : (Float64 -> String)? = nil,
                   &on_change : Float64 ->) : Response
      response = add(DragValue.new(value, speed, prefix, suffix, format))
      if response.changed? && (v = response.widget_value)
        on_change.call(v)
      end
      response
    end

    # egui `ScrollArea::vertical().show(ui, …)`.
    def scroll_area(max_height : Float64? = nil, &block : Ui ->) : Rect
      ScrollArea.new(max_height).show(self) { |ui| yield ui }
    end

    def combo_box(id : String, selected : String, options : Array(String),
                  width : Float64 = 160.0, &on_select : String ->) : Bool
      ComboBox.new(id, selected, options, width).show(self) { |opt| on_select.call(opt) }
    end

    # egui `ui.text_edit_singleline(&mut String, hint)`: the block fires
    # with the new buffer whenever it changed this frame.
    def text_edit_singleline(buffer : String, hint : String? = nil,
                             &on_change : String ->) : Response
      response = add(TextEdit.new(buffer, hint))
      if response.changed? && (text = response.widget_text)
        on_change.call(text)
      end
      response
    end

    # egui `TextEdit::multiline` (`ui.text_edit_multiline(&mut String)`):
    # a wrapping, multi-row editor — Enter breaks lines, Up/Down move
    # between them, the view scrolls to keep the caret visible. The
    # block fires with the new buffer whenever it changed this frame.
    def text_edit_multiline(buffer : String, hint : String? = nil,
                            rows : Int32 = 4,
                            &on_change : String ->) : Response
      response = add(TextEdit.new(buffer, hint, multiline: true, rows: rows))
      if response.changed? && (text = response.widget_text)
        on_change.call(text)
      end
      response
    end

    # egui `ui.image(texture, size)`.
    def image(texture_id : UInt64, size : Vec2,
              tint : Color32 = Color32.new(255, 255, 255, 255)) : Response
      add(Image.new(texture_id, size, tint))
    end

    # egui `ui.color_edit32(&mut color)`: the block fires with the new
    # color when the picker changed it this frame.
    def color_edit32(color : Color32, &on_change : Color32 ->) : Response
      response = add(ColorPicker.new(color))
      if response.changed? && (picked = response.widget_color)
        on_change.call(picked)
      end
      response
    end

    def hyperlink(url : String) : Response
      add(Hyperlink.new(url, url))
    end

    def hyperlink_to(label : String, url : String,
                     align : Symbol = :left) : Response
      add(Hyperlink.new(label, url, align))
    end

    # egui `ui.selectable_label(selected, text)` (upstream 0.36:
    # `Button::selectable`). The block form hands the new state back
    # when the row is clicked, like `#checkbox`.
    def selectable_label(selected : Bool, text : String) : Response
      add(SelectableLabel.new(selected, text))
    end

    def selectable(selected : Bool, text : String, &on_change : Bool ->) : Response
      response = add(SelectableLabel.new(selected, text))
      on_change.call(!selected) if response.changed?
      response
    end

    # Switch-style toggle; block form like `#checkbox`.
    def toggle_button(checked : Bool, text : String? = nil,
                      &on_change : Bool ->) : Response
      response = add(ToggleButton.new(checked, text))
      on_change.call(!checked) if response.changed?
      response
    end

    # One-of-many segmented selector; the block fires with the newly
    # selected index.
    def segmented(selected : Int32, labels : Array(String),
                  &on_select : Int32 ->) : Response
      response = add(SegmentedControl.new(selected, labels))
      if response.changed? && (v = response.widget_value)
        on_select.call(v.to_i)
      end
      response
    end

    # egui_extras `DatePickerButton` — see `DatePicker`. The block
    # fires from inside #show on the day click (and Today).
    def date_picker(id : String, value : Time,
                    format : String = "%Y-%m-%d",
                    &on_change : Time ->) : Response
      add(DatePicker.new(id, value, format, &on_change))
    end

    # egui_plot-style line/scatter plot; see `Plot`.
    def plot(id : String, height : Float64 = 200.0, &block : Plot ->) : Response
      p = Plot.new(id, height)
      block.call(p)
      add(p)
    end

    # egui `ui.grid(id) { |grid| … }` — aligned columns; see `Grid`.
    def grid(id : String, striped : Bool = false, &block : Grid ->) : Rect
      Grid.new(id, striped: striped).show(self) { |g| yield g }
    end

    # Hierarchical list; see `TreeView`.
    def tree_view(id : String, &block : TreeView ->) : Nil
      TreeView.new(id).show(self) { |tree| yield tree }
    end

    # Header + body table; see `Table`.
    def table(id : String, headers : Array(String),
              fractions : Array(Float64)? = nil, &block : Grid ->) : Nil
      Table.new(id, headers, fractions).show(self) { |rows| yield rows }
    end

    # egui `ui.add_sized(size, widget)` — lay the widget out in an
    # exact-size cell instead of its natural size.
    def add_sized(size : Vec2, widget : Widget) : Response
      rect = Rect.from_min_size(@cursor, size)
      @min_rect = @min_rect.union(rect)
      @cursor = @layout.advance(@cursor, size, style.spacing.item_spacing)
      cell = child_ui(rect)
      widget.ui(cell)
    end

    # egui `ui.scope` — a nested region with its own id space (children
    # mint ids under the scope's id, not the parent's counter).
    def scope(&block : Ui ->) : self
      child = child_ui(
        Rect.new(@cursor, Pos2.new(@max_rect.right, @max_rect.bottom)))
      yield child
      @min_rect = @min_rect.union(child.min_rect)
      @cursor = Pos2.new(@max_rect.min.x,
        child.min_rect.bottom + style.spacing.item_spacing.y)
      self
    end

    # egui `ui.columns(n)` — split the remaining width into `n` equal
    # columns; the block receives one Ui per column.
    def columns(n : Int32, &block : Array(Ui) ->) : Nil
      spacing = style.spacing.item_spacing.x
      gap_total = spacing * (n - 1)
      col_w = {(available_width - gap_total) / {n, 1}.max, 1.0}.max
      cols = (0...n).map do |i|
        x = @cursor.x + i * (col_w + spacing)
        child_ui(Rect.from_min_size(Pos2.new(x, @cursor.y),
          Vec2.new(col_w, available_height)))
      end
      yield cols
      cols.each { |c| @min_rect = @min_rect.union(c.min_rect) }
      bottom = cols.map(&.min_rect.bottom).max
      @cursor = Pos2.new(@max_rect.min.x, bottom + style.spacing.item_spacing.y)
    end

    # egui `ui.enabled(flag, |ui| …)` — gray-out + interaction-block a
    # region. Contents ALWAYS render through a child Ui so widget ids
    # stay stable when the flag flips (interaction state must survive
    # disable/enable cycles). While disabled every Response comes back
    # dead and a translucent scrim is back-painted over the region.
    def enabled(flag : Bool, &block : Ui ->) : Nil
      scrim_index = painter.add_noop
      child = child_ui(
        Rect.new(@cursor, Pos2.new(@max_rect.right, @max_rect.bottom)))

      if flag
        yield child
      else
        @ctx.memory.push_disabled
        yield child
        @ctx.memory.pop_disabled
      end

      @min_rect = @min_rect.union(child.min_rect)
      @cursor = Pos2.new(@max_rect.min.x,
        child.min_rect.bottom + style.spacing.item_spacing.y)
      return if flag
      v = style.visuals
      painter.set(scrim_index,
        RectCmd.new(painter.clip, child.min_rect, 0.0,
          v.fade_color(v.panel_fill, 0.5), nil, 0.0))
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
    # Built through #child_ui so the row inherits the parent's layer and
    # clip rect — a horizontal row inside a window/scroll area must stay
    # in that layer's z-order and viewport clip.
    def horizontal(&block : Ui ->) : self
      row = child_ui(
        Rect.new(@cursor, Pos2.new(@max_rect.right, @max_rect.bottom)),
        layout: Layout.left_to_right)
      yield row
      @min_rect = @min_rect.union(row.min_rect)
      @cursor = Pos2.new(@max_rect.min.x,
        row.min_rect.bottom + style.spacing.item_spacing.y)
      self
    end
  end
end
