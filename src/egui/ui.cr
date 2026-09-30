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
    # CSS `overflow-y`: when true, vertical allocations are NOT
    # clamped to `max_rect`'s bottom edge — content may extend below
    # (clipped by `clip`, scrollable through a ScrollArea viewport)
    # instead of collapsing into zero-height rows. `available_height`
    # stays bounded by `max_rect`, so fill-height widgets keep sizing
    # to the viewport. Set by `ScrollArea#show` on its inner Ui.
    property v_overflow : Bool = false

    @child_counter : UInt64 = 0

    # Horizontal-row cross-axis extent (upstream's cursor cross sides):
    # the height of the row built so far — the max of every widget
    # placed on it, seeded by #horizontal with `interact_size.y`
    # (upstream's initial row height). Each new widget is vertically
    # CENTERED within it (upstream `Layout::cross_align == Align::Center`
    # for horizontal layouts), and the row only ever grows DOWN
    # (upstream: "for horizontal layouts we always want to expand down,
    # or we will overlap the row above"). Without this every widget in
    # a mixed-height row (checkbox + label + DragValue) top-aligns and
    # their centers scatter by a pixel or two. Only read for
    # left_to_right layouts.
    @row_h : Float64 = 0.0

    # Seed the row height (see #@row_h): #horizontal and #add_sized open
    # a row whose baseline height is known upfront.
    def seed_row_height(h : Float64) : Nil
      @row_h = {@row_h, h}.max
    end

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

    # The font stack this Ui's text measures through: the theme's
    # `font_family` resolved via `Context#fonts_for` (nil family = the
    # primary stack). Widgets whose effective style carries a family
    # (class rules / inline / inspector cascade) resolve their own
    # `ctx.fonts_for(style.font_family)` instead — this helper is the
    # "whatever the ambient theme says" default.
    def fonts : Fonts
      @ctx.fonts_for(style.font_family)
    end

    def painter : Painter
      @ctx.painter
    end

    # egui `ui.next_auto_id()`: parent id + incrementing child salt.
    def next_widget_id : Id
      @child_counter += 1
      @id.child(@child_counter)
    end

    # A stable, route-addressable widget id: this Ui's id + the name.
    # When the router owes this page a focus fragment (`root/page#name`
    # from `--page` or navigate) and `name` matches, the id is also
    # given keyboard focus right away — that is how deep links land on
    # a widget. Widgets opt in via their `focus_id:` parameter.
    def named_id(name : String) : Id
      id = @id.child(Id.from("named/#{name}").value)
      if (router = @ctx.router?) && router.fragment_armed?(name)
        @ctx.memory.focus.request(id)
      end
      id
    end

    # Global DEFAULT widget size (egui.cr, no upstream counterpart):
    # the fallback floor a widget falls back to when neither its
    # content nor an explicit size (`min_size:`, `add_sized`) defines
    # one — a widget may be larger, but its size never collapses to
    # zero. Window-frame chrome is exempt (it passes its own exact
    # sizes). Panels have their own default (`Context::PANEL_MIN_SIZE`).
    DEFAULT_WIDGET_SIZE = 10.0

    # egui `Ui::allocate_at_least`: place a widget of `size` at the
    # cursor, grow `min_rect`, advance the cursor.
    #
    # Max-size rule (egui.cr guarantee, no upstream counterpart): a
    # widget rect never extends past `max_rect`'s far corner — the
    # effective max width/height of every widget is at least bounded
    # by its parent region. How a widget FITS inside the bound is the
    # widget's own policy (Label `wrap`, TextEdit horizontal scroll,
    # plain clipping otherwise); this is the hard floor that makes
    # "long content grows past the parent" impossible. Regions with a
    # semi-infinite `max_rect` (frames, scroll contents) are
    # unaffected by the clamp — and so are `v_overflow` regions (CSS
    # `overflow-y`: the content grows past the bottom on purpose,
    # clipped by `clip` and scrolled by the owning ScrollArea).
    def allocate_space(size : Vec2) : Rect
      max_x = { {@cursor.x + size.x, @max_rect.right}.min, @cursor.x }.max
      if @layout.horizontal?
        # Cross-axis centering (see #@row_h): center the widget within
        # the current row height, clamped to this region's bottom by
        # the max-size rule like everything else.
        @row_h = {@row_h, size.y}.max
        top = @cursor.y + (@row_h - size.y) / 2.0
        raw_bottom = top + size.y
        max_y = @v_overflow ? raw_bottom : {raw_bottom, @max_rect.bottom}.min
        max_y = {max_y, @cursor.y}.max
        rect = Rect.new(Pos2.new(@cursor.x, top), Pos2.new(max_x, max_y))
        # The row slice (upstream's frame rect) reserves the FULL row
        # height even when the centered widget doesn't reach its bottom
        # edge — otherwise the region's bounding box would depend on
        # widget order.
        frame_bottom = @v_overflow ? @cursor.y + @row_h
                                   : {@cursor.y + @row_h, @max_rect.bottom}.min
        @min_rect = @min_rect.union(
          Rect.new(@cursor, Pos2.new(max_x, {frame_bottom, @cursor.y}.max)))
      else
        raw_y = @cursor.y + size.y
        max_y = @v_overflow ? raw_y : {raw_y, @max_rect.bottom}.min
        max_y = {max_y, @cursor.y}.max
        rect = Rect.new(@cursor, Pos2.new(max_x, max_y))
        @min_rect = @min_rect.union(rect)
      end
      @cursor = @layout.advance(@cursor, rect.size,
        style.spacing.item_spacing)
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
    # Inherits the parent's layer, clip rect AND vertical-overflow mode
    # (`v_overflow` — the CSS overflow-y semantics of a scroll
    # viewport must reach the whole subtree: without this, rows built
    # through `#horizontal`/`#scope` near the fold would clamp their
    # children to the viewport's bottom edge and overlap there).
    def child_ui(max_rect : Rect, id : Id? = nil,
                 layout : Layout = Layout.top_down) : Ui
      child = Ui.new(@ctx, id || next_widget_id, max_rect, layout)
      child.layer = @layer
      child.clip = @clip
      child.v_overflow = @v_overflow
      child
    end

    # egui `Ui::add(widget)` — the generic Widget entry point. While
    # the widget runs, it is the Context's `current_widget` — the
    # inspector records kind/class/properties per id from it (nil for
    # interact calls not coming from an `Ui#add`).
    def add(widget : Widget) : Response
      parent = @ctx.current_widget
      @ctx.current_widget = widget
      begin
        Egui::Bench.span(widget.class.name) { widget.ui(self) }
      ensure
        @ctx.current_widget = parent
      end
    end

    # egui `ui.label` — selectable text by default (`userselect: false`
    # for the inert paint-only label). `wrap` nil (default) wraps the
    # label against the available width in a vertical layout; `true`
    # wraps always, `false` never.
    def label(text : String, wrap : Bool? = nil,
              userselect : Bool = true) : Response
      add(Label.new(text, wrap: wrap, userselect: userselect))
    end

    # egui `ui.label(RichText)`.
    def rich(text : RichText, wrap : Bool? = nil,
             userselect : Bool = true) : Response
      add(Label.new(text, wrap: wrap, userselect: userselect))
    end

    def heading(text : String) : Response
      rich(RichText.new(text).heading(style.font_size))
    end

    def button(text : String, id : String? = nil) : Response
      add(Button.new(text, id: id))
    end

    # A block-level button filling the region's width — the Windows
    # dialog idiom, where `#button` is the inline (content-hugging)
    # one. `height` overrides the 40pt default.
    def big_button(text : String, height : Float64 = 40.0) : Response
      add(Button.new(text).min_size(Vec2.new(available_width, height)))
    end

    # egui `ui.checkbox(&mut bool, text)` — Crystal keeps the value in
    # app state; the block fires with the new value on toggle, and
    # `Response#changed?` reports the same on the returned Response.
    def checkbox(checked : Bool, text : String, id : String? = nil,
                 &on_change : Bool ->) : Response
      response = add(Checkbox.new(checked, text, id: id))
      on_change.call(!checked) if response.changed?
      response
    end

    def checkbox(checked : Bool, text : String, id : String? = nil) : Response
      add(Checkbox.new(checked, text, id: id))
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

    # Vector SVG (mini parser → painter primitives); see `Egui::Svg`.
    def svg(source : String, size : Vec2 = Vec2.new(128.0, 128.0),
            current_color : Color32 = Svg::BLACK) : Response
      add(Svg.new(source, size, current_color))
    end

    # egui `ui.hyperlink(url)` / `ui.hyperlink_to(label, url)`.
    # egui `ui.add_enabled`-style block helpers for value widgets:
    # the block fires with the new value when it changed this frame.
    def slider(value : Float64, range : Range(Float64, Float64),
               text : String? = nil, id : String? = nil,
               &on_change : Float64 ->) : Response
      response = add(Slider.new(value, range, text, id: id))
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

    # Windows-style integer spin box (`NumberInput`): digits-only field
    # with up/down arrow buttons; the block fires with the new Int32 on
    # every commit (arrow click, Enter, blur, wheel, arrow keys).
    def number_input(value : Int32, range : Range(Int32, Int32)? = nil,
                     step : Int32 = 1, prefix : String = "",
                     suffix : String = "",
                     &on_change : Int32 ->) : Response
      response = add(NumberInput.new(value, range, step, prefix, suffix))
      if response.changed? && (v = response.widget_value)
        on_change.call(v.to_i32)
      end
      response
    end

    # egui `ScrollArea::vertical().show(ui, …)`. `scrollbar: :classic`
    # switches the flavor: a separate Win95/XP-style strip beside the
    # content (arrow buttons, paging track) instead of the thin bar
    # overlaying the edge. Bar placement per axis: `vbar: :left` moves
    # the vertical bar to the left edge; `hbar: :bottom`/`:top` turns
    # on horizontal scrolling with the bar on that edge (see ScrollArea).
    def scroll_area(max_height : Float64? = nil, scrollbar : Symbol = :overlay,
                    vbar : Symbol = :right, hbar : Symbol? = nil,
                    &block : Ui ->) : Rect
      ScrollArea.new(max_height, scrollbar, vbar, hbar)
        .show(self) { |ui| yield ui }
    end

    # `variant:` picks the closed-combo look (`:button` separated arrow
    # strip, `:plain` rigid single button, `:field` input field + select
    # button); `label:` is a placeholder for the empty selection that
    # also leads the list as the zero option (picking it reports "");
    # `overlay:` opens the list on top of the button, GTK3-style.
    def combo_box(id : String, selected : String, options : Array(String),
                  width : Float64? = nil, variant : Symbol = :button,
                  label : String? = nil, overlay : Bool = false,
                  &on_select : String ->) : Bool
      ComboBox.new(id, selected, options, width, variant, label, overlay)
        .show(self) { |opt| on_select.call(opt) }
    end

    # egui `egui::ComboBox` + search: a SelectBox — a searchable
    # select for option lists too long to scan linearly (the font
    # family catalog). See `widgets/select_box.cr`.
    def select_box(id : String, selected : String, options : Array(String),
                   width : Float64? = nil, label : String? = nil,
                   max_height : Float64 = 220.0,
                   &on_select : String ->) : Bool
      SelectBox.new(id, selected, options, width, label, max_height)
        .show(self) { |opt| on_select.call(opt) }
    end

    # --- reactive bindings (see reactive.cr) -------------------------------
    #
    # The `Signal` forms of the value widgets above: display + write-back
    # in one call, no `on_change` block, no app-field to copy into. The
    # write lands directly in the signal — bindings run inside the frame,
    # so no repaint request is needed (the driving event already bought
    # the settle repaints).

    def slider(sig : Signal(Float64), range : Range(Float64, Float64),
               text : String? = nil) : Response
      response = add(Slider.new(sig.value, range, text))
      if response.changed? && (v = response.widget_value)
        sig.value = v
      end
      response
    end

    def drag_value(sig : Signal(Float64), speed : Float64 = 1.0,
                   prefix : String = "", suffix : String = "",
                   format : (Float64 -> String)? = nil) : Response
      response = add(DragValue.new(sig.value, speed, prefix, suffix, format))
      if response.changed? && (v = response.widget_value)
        sig.value = v
      end
      response
    end

    def number_input(sig : Signal(Int32), range : Range(Int32, Int32)? = nil,
                     step : Int32 = 1, prefix : String = "",
                     suffix : String = "") : Response
      response = add(NumberInput.new(sig.value, range, step, prefix, suffix))
      if response.changed? && (v = response.widget_value)
        sig.value = v.to_i32
      end
      response
    end

    def checkbox(sig : Signal(Bool), text : String) : Response
      response = add(Checkbox.new(sig.value, text))
      sig.value = !sig.value if response.changed?
      response
    end

    def toggle_button(sig : Signal(Bool), text : String? = nil) : Response
      response = add(ToggleButton.new(sig.value, text))
      sig.value = !sig.value if response.changed?
      response
    end

    def selectable(sig : Signal(Bool), text : String) : Response
      response = add(SelectableLabel.new(sig.value, text))
      sig.value = !sig.value if response.changed?
      response
    end

    def text_field(sig : Signal(String), hint : String? = nil,
                   password : Bool = false) : Response
      response = add(TextEdit.new(sig.value, hint, password))
      if response.changed? && (text = response.widget_text)
        sig.value = text
      end
      response
    end

    def textarea(sig : Signal(String), hint : String? = nil,
                 rows : Int32 = 8, frame : Bool = true) : Response
      response = add(TextArea.new(sig.value, hint, rows, frame))
      if response.changed? && (text = response.widget_text)
        sig.value = text
      end
      response
    end

    def combo_box(id : String, sig : Signal(String), options : Array(String),
                  width : Float64? = nil, variant : Symbol = :button,
                  label : String? = nil, overlay : Bool = false) : Bool
      ComboBox.new(id, sig.value, options, width, variant, label, overlay)
        .show(self) { |opt| sig.value = opt }
    end

    # egui `ui.text_edit_singleline(&mut String, hint)`: the block fires
    # with the new buffer whenever it changed this frame. `password:
    # true` masks the display with circles (one per character).
    def text_edit_singleline(buffer : String, hint : String? = nil,
                             password : Bool = false,
                             focus_id : String? = nil,
                             frame : Bool = true,
                             &on_change : String ->) : Response
      response = add(TextEdit.new(buffer, hint, password, focus_id, frame))
      if response.changed? && (text = response.widget_text)
        on_change.call(text)
      end
      response
    end

    # egui `ui.text_edit_multiline` — here an HTML-textarea-shaped
    # widget: soft wrap, `rows` lines tall, its own kinetic scroll.
    def textarea(buffer : String, hint : String? = nil, rows : Int32 = 8,
                 frame : Bool = true,
                 &on_change : String ->) : Response
      response = add(TextArea.new(buffer, hint, rows, frame))
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

    # A pixel Canvas with Paint-style interaction; the block receives
    # this frame's Canvas::Interaction (pointer/drag in pixel coords).
    def canvas(canvas : Canvas, & : Canvas::Interaction ->) : Response
      ia = canvas.show(self)
      yield ia
      ia.response
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

    def hyperlink_to(label : String, url : String, id : String? = nil) : Response
      add(Hyperlink.new(label, url, id: id))
    end

    # egui `ui.selectable_label(selected, text)` (upstream 0.36:
    # `Button::selectable`). The block form hands the new state back
    # when the row is clicked, like `#checkbox`.
    def selectable_label(selected : Bool, text : String, id : String? = nil) : Response
      add(SelectableLabel.new(selected, text, id: id))
    end

    def selectable(selected : Bool, text : String, id : String? = nil,
                   &on_change : Bool ->) : Response
      response = add(SelectableLabel.new(selected, text, id: id))
      on_change.call(!selected) if response.changed?
      response
    end

    def selectable(selected : Bool, text : String, id : String? = nil) : Response
      add(SelectableLabel.new(selected, text, id: id))
    end

    # Switch-style toggle; block form like `#checkbox`.
    def toggle_button(checked : Bool, text : String? = nil,
                      id : String? = nil, &on_change : Bool ->) : Response
      response = add(ToggleButton.new(checked, text, id: id))
      on_change.call(!checked) if response.changed?
      response
    end

    def toggle_button(checked : Bool, text : String? = nil,
                      id : String? = nil) : Response
      add(ToggleButton.new(checked, text, id: id))
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

    # egui_plot-style line/scatter plot; see `Plot`. `animated: true`
    # adds live-plot behavior: double-click (or the overlay button)
    # resets a manually panned/zoomed view back to the default.
    # `draggable: false` makes it read-only (no pan/zoom, default view).
    # `reset_button: false` hides the reset pill that otherwise appears
    # on any panned/zoomed plot.
    def plot(id : String, height : Float64 = 200.0, animated : Bool = false,
             draggable : Bool = true, reset_button : Bool = true,
             &block : Plot ->) : Response
      p = Plot.new(id, height: height, animated: animated,
        draggable: draggable, reset_button: reset_button)
      block.call(p)
      add(p)
    end

    # egui `ui.grid(id) { |grid| … }` — aligned columns; see `Grid`.
    def grid(id : String, &block : Grid ->) : Rect
      Grid.new(id).show(self) { |g| yield g }
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
    # exact-size cell instead of its natural size (still bounded by
    # the region's max_rect, like every allocation).
    #
    # The cell is a HARD bound: unlike flow regions (#horizontal,
    # #scope, scroll content) it does NOT inherit `v_overflow` — a
    # widget placed in an exact-size cell can never outgrow it, even
    # inside a scrollable panel. Without this, a fixed-height header
    # cell (the Inspector's ✕) lets the natural-size button inside
    # grow past the row and overlap what's below.
    def add_sized(size : Vec2, widget : Widget) : Response
      rect = allocate_space(size)
      # Upstream `allocate_ui` keeps the PARENT layout for the cell: in
      # a horizontal row the cell is left_to_right too, so its content
      # cross-centers within the exact cell instead of hugging its top
      # (a Label in a 20pt cell would sit 2px low otherwise). Vertical
      # parents keep the top_down cell unchanged.
      if @layout.horizontal?
        cell = child_ui(rect, layout: Layout.left_to_right)
        cell.seed_row_height(rect.height)
      else
        cell = child_ui(rect)
      end
      cell.v_overflow = false
      # Same current_widget bookkeeping as #add — #interact records
      # inspector meta from it, and widgets placed through #add_sized
      # (the Inspector header's Export/✕ buttons) must not be the only
      # unpickable widgets on screen.
      parent = @ctx.current_widget
      @ctx.current_widget = widget
      begin
        Egui::Bench.span(widget.class.name) { widget.ui(cell) }
      ensure
        @ctx.current_widget = parent
      end
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
      # Upstream seeds the row at `interact_size.y` ("assume there will
      # be something interactive on the horizontal layout") so short
      # widgets share a common center line before anything tall grows
      # the row — and a row of short widgets keeps a sane height.
      row.seed_row_height(style.spacing.interact_size.y)
      yield row
      @min_rect = @min_rect.union(row.min_rect)
      @cursor = Pos2.new(@max_rect.min.x,
        row.min_rect.bottom + style.spacing.item_spacing.y)
      self
    end
  end
end
