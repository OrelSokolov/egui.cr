# Port of egui_upstream/crates/egui/src/ui.rs.
#
# `Ui` is a layout region: a cursor advancing through `max_rect`,
# minting child ids, and handing widgets their rects + `Response`s.
# Everything here mirrors the upstream mechanics kept for slice 1:
# `allocate_at_least` → `interact` → paint → return Response.

module Egui
  # Virtualization bookkeeping a `virtual:` ScrollArea pushes onto its
  # inner Ui (consumed by `Ui#virtual_row`): the per-row extent cache
  # (shared with Memory — it survives frames) and the visible band, in
  # the inner Ui's own coordinates, padded by the scroll's margin.
  class VirtualRowState
    getter heights : Hash(UInt64, Tuple(Float64, UInt64))
    getter band_top : Float64
    getter band_bottom : Float64

    def initialize(@heights, @band_top, @band_bottom)
    end

    def visible?(top : Float64, bottom : Float64) : Bool
      bottom >= @band_top && top <= @band_bottom
    end
  end

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
    # Virtual-scroll state (see ScrollArea `virtual:`): set on the
    # scroll's inner Ui, inherited by child regions — #virtual_row
    # reads it. Nil outside a virtual scroll.
    property virtual_rows : VirtualRowState? = nil
    # CSS-like style scope (see #with_style_scope): the dotted class
    # prefix widgets added through this Ui style under — nil = no
    # scope, widgets ride their plain `style_class`. A child Ui
    # inherits it (see #child_ui), so scoping is opt-in per container
    # and flows down the whole subtree.
    getter style_scope : String?
    # CSS containing block for `position: absolute` descendants (see
    # Ui#box_positioning): the rect of the nearest positioned (`position:
    # relative|absolute|fixed`) ancestor box, inherited by child Ui's —
    # nil = none yet, `absolute` then falls back to the viewport
    # (`fixed` always uses the viewport, CSS semantics).
    property pos_context : Rect?

    # Horizontal-row line wrapping (CSS `flex-wrap: wrap`, on by
    # default in #horizontal): when the next widget does not fit the
    # remaining row width — and would fit on a fresh line — the
    # cursor breaks to a new line instead of pinning the widget at
    # the region edge as a zero-remainder rect. Mobile-safe default:
    # nothing runs off the screen edge just because a row overflows.
    property wrap_x : Bool = false

    # Cross-axis growth direction of a horizontal row (see #horizontal
    # and #allocate_space): true only for a row opened inside an
    # up-flowing (bottom_up) region — the row band then hugs the flow
    # line from above and grows upward, instead of the default
    # downward growth. Never set by hand; #horizontal flips it.
    property cross_up : Bool = false

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

    # The exact-size cell of #add_sized, when this Ui is one (nil for
    # every flow region). A widget in an exact cell FILLS it — the
    # upstream `add_sized` contract ("make the widget exactly this
    # size"): the natural/content size only governs layout in flow
    # regions, in a sized cell it is the CELL that wins (see
    # #allocate_at_least). Not inherited by child regions — only the
    # single widget placed by #add_sized sees it.
    @exact_cell : Rect? = nil

    protected def exact_cell=(rect : Rect?) : Nil
      @exact_cell = rect
    end

    def initialize(@ctx : Context, @id : Id, @max_rect : Rect,
                   @layout : Layout = Layout.top_down)
      # rendering_direction :up (bottom_up layout, dialogue mode): the
      # cursor starts at the region's bottom-left corner and the flow
      # marches upward; every other direction starts at the top-left.
      @cursor = @layout.bottom_up? ? Pos2.new(@max_rect.min.x, @max_rect.bottom)
                                   : @max_rect.min
      @min_rect = Rect.new(@cursor, @cursor)
      @layer = LayerId.background
      @clip = Rect.infinite
      @style_scope = nil
    end

    # rendering_direction (`:down` by default, `:up` for the bottom_up
    # layout): the vertical axis this region lays widgets out along.
    # Architectural, not per-widget — every widget places itself
    # through #allocate_space, so labels, buttons, frames, rows… all
    # flip together with the region (see #with_rendering_direction).
    def rendering_direction : Symbol
      @layout.bottom_up? ? :up : :down
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
      if @layout.horizontal? && @wrap_x
        # Line wrap (see #wrap_x): break to a fresh line when the
        # widget cannot fit the remainder but fits a full line. A
        # widget wider than the WHOLE row stays put (the max-size
        # clamp applies, as before wrapping existed). A wrapped
        # galley may overshoot the row width by a hair (rounding, a
        # word slightly wider than the wrap limit) — tolerate up to
        # one item spacing so such a widget still breaks to a fresh
        # line instead of collapsing into the end-of-row sliver.
        remaining = @max_rect.right - @cursor.x
        if @cursor.x > @max_rect.min.x && size.x > remaining &&
           size.x <= @max_rect.width + style.spacing.item_spacing.x
          step = @row_h + style.spacing.item_spacing.y
          @cursor = Pos2.new(@max_rect.min.x,
            @cursor.y + (@cross_up ? -step : step))
          @row_h = 0.0 # the new line's height starts fresh
        end
      end
      max_x = { {@cursor.x + size.x, @max_rect.right}.min, @cursor.x }.max
      if @layout.horizontal?
        # Cross-axis centering (see #@row_h): center the widget within
        # the current row height, clamped to this region's far edge by
        # the max-size rule like everything else. In an up-flowing
        # parent (#cross_up) the row band hugs the flow line from
        # ABOVE and grows upward — the mirror of "horizontal rows
        # always expand down, or we will overlap the row above".
        @row_h = {@row_h, size.y}.max
        if @cross_up
          bottom = @cursor.y - (@row_h - size.y) / 2.0
          raw_top = bottom - size.y
          min_y = @v_overflow ? raw_top : {raw_top, @max_rect.min.y}.max
          min_y = {min_y, @cursor.y}.min
          rect = Rect.new(Pos2.new(@cursor.x, min_y), Pos2.new(max_x, bottom))
          frame_top = @v_overflow ? @cursor.y - @row_h
                                  : {@cursor.y - @row_h, @max_rect.min.y}.max
          @min_rect = @min_rect.union(
            Rect.new(Pos2.new(@cursor.x, {frame_top, @cursor.y}.min),
              Pos2.new(max_x, @cursor.y)))
        else
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
        end
      elsif @layout.bottom_up?
        # rendering_direction :up — the mirror of the top_down branch
        # below: the rect sits ABOVE the cursor, the max-size rule
        # clamps it to max_rect's top edge (v_overflow lets content
        # grow past it, CSS overflow-y flipped).
        raw_min_y = @cursor.y - size.y
        min_y = @v_overflow ? raw_min_y : {raw_min_y, @max_rect.min.y}.max
        min_y = {min_y, @cursor.y}.min
        rect = Rect.new(Pos2.new(@cursor.x, min_y), Pos2.new(max_x, @cursor.y))
        @min_rect = @min_rect.union(rect)
      else
        raw_y = @cursor.y + size.y
        max_y = @v_overflow ? raw_y : {raw_y, @max_rect.bottom}.min
        max_y = {max_y, @cursor.y}.max
        rect = Rect.new(@cursor, Pos2.new(max_x, max_y))
        @min_rect = @min_rect.union(rect)
      end
      @cursor = @layout.advance(@cursor, rect.size,
        style.spacing.item_spacing)
      # A clamped allocation must not march the cursor past the
      # region's far edge (egui.cr fix, no upstream counterpart): in
      # an already-full horizontal row the follow-up widgets would get
      # zero-size rects BEYOND max_rect — outside the clip, out in the
      # panel padding — each marching one item_spacing further. Pin
      # them at the edge instead; they still don't fit, and the
      # widget's own policy (Button's ellipsis) renders what it can.
      # VERTICAL stays as-is: below-the-fold widgets in a bounded
      # region march down on purpose and the painter's row culling
      # hides them, so pinning them at the fold would stack them
      # visibly on the last fitting row.
      if @layout.horizontal?
        @cursor = Pos2.new({@cursor.x, @max_rect.right}.min, @cursor.y)
      end
      rect
    end

    def allocate_at_least(size : Vec2) : Rect
      # Exact-size cell (#add_sized): the widget fills the cell — the
      # upstream contract. Without this a sized Button hugs its natural
      # size at the cell's start (allocate_space only CLAMPS to
      # max_rect, it never grows UP to it), which is the "inline, not
      # block" look. The cell rect is already allocated and the parent
      # cursor already advanced (#add_sized did allocate_space itself),
      # so there is nothing else to do here.
      return @exact_cell.not_nil! if @exact_cell
      allocate_space(size)
    end

    # End the current horizontal row: the cursor breaks to a fresh
    # line below (above in an up-flowing row) — upstream
    # `Layout::end_line`, the layout primitive behind the HTML `<br>`
    # hard break. Unlike the wrap branch of #allocate_space this is a
    # REQUESTED break: it fires in no-wrap rows too (span, toolbars),
    # where nothing else can move the cursor off the line, and even at
    # a line's start (`<br>` on its own line yields an empty line). A
    # no-op in vertical flow, where every widget already starts its
    # own line.
    def end_line : Nil
      return unless @layout.horizontal?
      step = @row_h + style.spacing.item_spacing.y
      @cursor = Pos2.new(@max_rect.min.x,
        @cursor.y + (@cross_up ? -step : step))
      @row_h = 0.0
    end

    # egui `Ui::interact` — delegates to Context/Memory.
    def interact(rect : Rect, id : Id, sense : Sense) : Response
      @ctx.interact(id, rect, sense, @layer, @clip)
    end

    # egui `Ui::new_child`: a child region with its own cursor/layout.
    # Inherits the parent's layer, clip rect, vertical-overflow mode
    # (`v_overflow` — the CSS overflow-y semantics of a scroll
    # viewport must reach the whole subtree: without this, rows built
    # through `#horizontal`/`#scope` near the fold would clamp their
    # children to the viewport's bottom edge and overlap there), style
    # scope (a widget inside stays inside the scope) AND the vertical
    # rendering direction — a child of an up-flowing region flows up
    # too, unless the caller passes an explicit layout (the #horizontal
    # row is always left_to_right; panels are pinned top_down).
    def child_ui(max_rect : Rect, id : Id? = nil,
                 layout : Layout? = nil) : Ui
      child = Ui.new(@ctx, id || next_widget_id, max_rect,
        layout || (@layout.bottom_up? ? Layout.bottom_up : Layout.top_down))
      child.layer = @layer
      child.clip = @clip
      child.v_overflow = @v_overflow
      child.virtual_rows = @virtual_rows
      # Menu rows inside a child Ui (e.g. `Ui#enabled` blocks grouping
      # disabled items) must still close their popup on click.
      child.menu_popup_key = @menu_popup_key
      child.set_style_scope(@style_scope)
      child.pos_context = @pos_context
      child
    end

    # CSS-like scoping for complex components: while the block runs,
    # widgets added through this Ui carry an extra class path
    # `"{scope}.{own class}"` on top of their base `style_class` (see
    # `Widget#class_paths`) — a Button inside `with_style_scope("sidebar")`
    # styles under BOTH "button" and "sidebar.button" without any
    # per-widget wiring. Scopes nest by dots ("sidebar" → "sidebar.toolbar").
    # Returns the block's value. The current scope is also mirrored on
    # the Context (inspector meta and paint-in-place `StyledPart`s read
    # it without a Ui).
    def with_style_scope(name : String, &)
      old = @style_scope
      old_ctx = @ctx.current_style_scope
      @style_scope = old ? "#{old}.#{name}" : name
      @ctx.current_style_scope = @style_scope
      begin
        yield self
      ensure
        @style_scope = old
        @ctx.current_style_scope = old_ctx
      end
    end

    # Internal: seed a child Ui's inherited scope (#child_ui).
    def set_style_scope(scope : String?) : Nil
      @style_scope = scope
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
    # wraps always, `false` never. `align:` (:left/:center/:right)
    # places the text inside the rect (nil = left).
    def label(text : String, wrap : Bool? = nil,
              userselect : Bool = true, align : Symbol? = nil) : Response
      add(Label.new(text, wrap: wrap, userselect: userselect, align: align))
    end

    # egui `ui.label(RichText)`.
    def rich(text : RichText, wrap : Bool? = nil,
             userselect : Bool = true, align : Symbol? = nil) : Response
      add(Label.new(text, wrap: wrap, userselect: userselect, align: align))
    end

    # A label that scrolls: wraps exactly like a TextArea, grows with
    # its content up to `max_height`, then scrolls (wheel / touch /
    # scrollbar). Read-only — selection and Copy work, editing doesn't.
    def scrolledlabel(text : String, max_height : Float64? = nil,
                      id : String? = nil) : Response
      add(ScrolledLabel.new(text, max_height, id))
    end

    def heading(text : String) : Response
      rich(RichText.new(text).heading(style.font_size))
    end

    def button(text : String, id : String? = nil) : Response
      add(Button.new(text, id: id))
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

    # Rendered markdown (headings, lists, quotes, code blocks, rules,
    # images — inline `**bold**`/`*italic*`/`` `code` ``/links through
    # RichLabel). `base_dir` roots relative image paths. See
    # `Egui::Markdown`.
    def markdown(source : String, base_dir : String? = nil,
                 id : String? = nil) : Response
      add(Markdown.new(source, base_dir: base_dir, id: id))
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

    # Animated vector (Lottie); see `Egui::Lottie::Player` and
    # `LottieWidget`. `size` defaults to the renderer's viewport.
    def lottie(player : Lottie::Player, size : Vec2? = nil) : Response
      add(LottieWidget.new(player, size))
    end

    # egui `ui.hyperlink(url)` / `ui.hyperlink_to(label, url)`.
    # egui `ui.add_enabled`-style block helpers for value widgets:
    # the block fires with the new value when it changed this frame.
    # `tips:` adds macOS-style {left, right} captions under the rail;
    # `quantized: true` restricts the value to `values:` (required) —
    # the handle snaps to the nearest list entry; `ticks:` draws a
    # vertical stroke per entry (`true`/`:down` under the rail, `:up`
    # above, `:up_down` both; requires `values:`); `handle:` picks the
    # handle shape (`:circle`, `:rect`, `:pentagon_up`, `:pentagon_down`).
    def slider(value : Float64, range : Range(Float64, Float64),
               text : String? = nil, id : String? = nil,
               tips : {String, String}? = nil, quantized : Bool = false,
               values : Array(Float64)? = nil, ticks : Bool | Symbol = false,
               handle : Symbol = :circle,
               &on_change : Float64 ->) : Response
      response = add(Slider.new(value, range, text, id: id, tips: tips,
        quantized: quantized, values: values, ticks: ticks,
        handle: handle))
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
                    virtual : Bool = false, &block : Ui ->) : Rect
      ScrollArea.new(max_height, scrollbar, vbar, hbar, nil, virtual).show(self, &block)
    end

    # A virtualized row of a `virtual:` ScrollArea: the row's extent
    # and widget-id span are cached across frames by `key` (stable
    # across the frame's content — a filtered list reuses the same
    # keys for the surviving rows). A row falling entirely outside the
    # visible band is NOT built — the cached extent is replayed into
    # the flow (cursor + min_rect) and the child-id counter advanced
    # by the row's recorded span, so the widget ids of LATER rows
    # never shift when rows are skipped (their Memory state — hover,
    # textarea scroll — is pruned with any other unseen widget, which
    # is the same contract as scrolling a virtualized table).
    #
    # The first frame — and the frame after a viewport width change,
    # which invalidates every cached height — builds all rows once to
    # measure them. Outside a virtual scroll the call is a plain block.
    #
    # Returns true when the row ran, false when it was skipped.
    def virtual_row(key : String, &) : Bool
      state = @virtual_rows
      unless state
        yield self
        return true
      end
      kh = Id.from(key).value
      top = @cursor.y
      if (cached = state.heights[kh]?) && !state.visible?(top, top + cached[0])
        h, id_span = cached
        @cursor = Pos2.new(@cursor.x, top + h)
        @min_rect = @min_rect.union(Rect.from_min_size(
          Pos2.new(@max_rect.min.x, top), Vec2.new(@max_rect.width, h)))
        @child_counter += id_span
        return false
      end
      counter_before = @child_counter
      yield self
      state.heights[kh] = {@cursor.y - top, @child_counter - counter_before}
      true
    end

    # A region-anchored floating block (`position: fixed`-style, see
    # `Egui::Overlay`): widgets laid out ON TOP of this region at one
    # of nine anchors with a margin from the pinned edges — the parent
    # flow is untouched. `rect:` re-bases it (the map's rect);
    # `pass_through: true` drops the background click target (HUD
    # overlays must not eat the map's drags). Anchor/margin/z also
    # style through the "overlay" class and are inspector-editable.
    def overlay(anchor : Symbol? = nil, margin : StyleBox? = nil,
                z : Int32? = nil, rect : Rect? = nil,
                pass_through : Bool = false, id : String? = nil,
                &block : Ui ->) : Response
      add(Overlay.new(anchor, margin, z, rect, pass_through, id) do |o|
        block.call(o)
      end)
    end

    # `variant:` picks the closed-combo look (`:button` separated arrow
    # strip, `:plain` rigid single button, `:field` input field + select
    # button); `label:` is a placeholder for the empty selection that
    # also leads the list as the zero option (picking it reports "");
    # `overlay:` opens the list on top of the button, GTK3-style;
    # `max_height:` caps the open list — beyond it the list scrolls.
    def combo_box(id : String, selected : String, options : Array(String),
                  width : Float64? = nil, variant : Symbol = :button,
                  label : String? = nil, overlay : Bool = false,
                  max_height : Float64 = 220.0,
                  &on_select : String ->) : Bool
      ComboBox.new(id, selected, options, width, variant, label, overlay,
        max_height).show(self) { |opt| on_select.call(opt) }
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
    #
    # Every form shares ONE skeleton (`signal_form`): add the widget,
    # push the new value into the signal when it changed this frame,
    # return the Response. Only the widget construction and the write
    # line differ per widget — no more hand-copied boilerplate.

    # :nodoc: the shared signal write-back skeleton. The block body
    # runs only when the widget changed; `response` is in scope.
    private macro signal_form(widget, &write)
      response = {{ widget }}
      if response.changed?
        {{ write.body }}
      end
      response
    end

    def slider(sig : Signal(Float64), range : Range(Float64, Float64),
               text : String? = nil, tips : {String, String}? = nil,
               quantized : Bool = false,
               values : Array(Float64)? = nil,
               ticks : Bool | Symbol = false,
               handle : Symbol = :circle) : Response
      signal_form add(Slider.new(sig.value, range, text, tips: tips,
        quantized: quantized, values: values, ticks: ticks,
        handle: handle)) do
        sig.value = response.widget_value.not_nil!
      end
    end

    def drag_value(sig : Signal(Float64), speed : Float64 = 1.0,
                   prefix : String = "", suffix : String = "",
                   format : (Float64 -> String)? = nil) : Response
      signal_form add(DragValue.new(sig.value, speed, prefix, suffix, format)) do
        sig.value = response.widget_value.not_nil!
      end
    end

    def number_input(sig : Signal(Int32), range : Range(Int32, Int32)? = nil,
                     step : Int32 = 1, prefix : String = "",
                     suffix : String = "") : Response
      signal_form add(NumberInput.new(sig.value, range, step, prefix, suffix)) do
        sig.value = response.widget_value.not_nil!.to_i32
      end
    end

    def checkbox(sig : Signal(Bool), text : String) : Response
      signal_form add(Checkbox.new(sig.value, text)) do
        sig.value = !sig.value
      end
    end

    def toggle_button(sig : Signal(Bool), text : String? = nil) : Response
      signal_form add(ToggleButton.new(sig.value, text)) do
        sig.value = !sig.value
      end
    end

    def selectable(sig : Signal(Bool), text : String) : Response
      signal_form add(SelectableLabel.new(sig.value, text)) do
        sig.value = !sig.value
      end
    end

    def text_field(sig : Signal(String), hint : String? = nil,
                   password : Bool = false,
                   cursor_style : Symbol = :line,
                   cursor_blinks : Bool = true) : Response
      signal_form add(TextEdit.new(sig.value, hint, password,
        cursor_style: cursor_style, cursor_blinks: cursor_blinks)) do
        sig.value = response.widget_text.not_nil!
      end
    end

    def textarea(sig : Signal(String), hint : String? = nil,
                 rows : Int32 = 8, frame : Bool = true,
                 cursor_style : Symbol = :line,
                 cursor_blinks : Bool = true) : Response
      signal_form add(TextArea.new(sig.value, hint, rows, frame,
        cursor_style: cursor_style, cursor_blinks: cursor_blinks)) do
        sig.value = response.widget_text.not_nil!
      end
    end

    # The select-shaped exception: ComboBox reports a picked option,
    # not a changed Response — the block writes the pick directly.
    def combo_box(id : String, sig : Signal(String), options : Array(String),
                  width : Float64? = nil, variant : Symbol = :button,
                  label : String? = nil, overlay : Bool = false,
                  max_height : Float64 = 220.0) : Bool
      ComboBox.new(id, sig.value, options, width, variant, label, overlay,
        max_height).show(self) { |opt| sig.value = opt }
    end

    # egui `ui.text_edit_singleline(&mut String, hint)`: the block fires
    # with the new buffer whenever it changed this frame. `password:
    # true` masks the display with circles (one per character).
    # `leading_icon` draws an SVG inside the field's left padding (a
    # search lens).
    def text_edit_singleline(buffer : String, hint : String? = nil,
                             password : Bool = false,
                             focus_id : String? = nil,
                             frame : Bool = true,
                             cursor_style : Symbol = :line,
                             cursor_blinks : Bool = true,
                             width : Float64? = nil,
                             leading_icon : Svg? = nil,
                             &on_change : String ->) : Response
      edit = TextEdit.new(buffer, hint, password, focus_id, frame,
        cursor_style, cursor_blinks, width, leading_icon)
      edit.width(width) if width
      response = add(edit)
      if response.changed? && (text = response.widget_text)
        on_change.call(text)
      end
      response
    end

    # egui `ui.text_edit_multiline` — here an HTML-textarea-shaped
    # widget: soft wrap, `rows` lines tall, its own kinetic scroll.
    def textarea(buffer : String, hint : String? = nil, rows : Int32 = 8,
                 frame : Bool = true, cursor_blinks : Bool = true,
                 &on_change : String ->) : Response
      response = add(TextArea.new(buffer, hint, rows, frame,
        cursor_blinks: cursor_blinks))
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

    # An image fetched from `url` (placeholder + spinner while it
    # loads); see `Egui::RemoteImage`.
    def remote_image(url : String, size : Vec2? = nil, fit : Bool = true) : Response
      add(RemoteImage.new(url, size, fit))
    end

    # A pixel Canvas with Paint-style interaction; the block receives
    # this frame's Canvas::Interaction (pointer/drag in pixel coords).
    def canvas(canvas : Canvas, & : Canvas::Interaction ->) : Response
      ia = canvas.show(self)
      yield ia
      ia.response
    end

    # A Canvas2D drawing surface; the block draws through the canvas
    # (recorded ops bake into the texture on this frame).
    def canvas2d(canvas : Canvas2D, & : Canvas2D ->) : Response
      yield canvas
      canvas.ui(self)
    end

    # A depth-tested 3D viewport with an orbit camera; the block draws
    # meshes through the frame it receives.
    def viewport3d(viewport : Viewport3D, & : Frame3D ->) : Response
      viewport.show(self) { |frame| yield frame }
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

    # egui_extras `DatePickerButton` — see `CalendarPicker`. The block
    # fires from inside #show on the day click (and Today).
    def calendar_picker(id : String, value : Time,
                        format : String = "%Y-%m-%d",
                        &on_change : Time ->) : Response
      add(CalendarPicker.new(id, value, format, &on_change))
    end

    # Windows 11–style date picker (wheel flyout, ✓/✕ footer) — see
    # `DatePicker`.
    def date_picker(id : String, value : Time, format : String = "%d.%m.%Y",
                    &on_change : Time ->) : Response
      add(DatePicker.new(id, value, format, &on_change))
    end

    # Windows 11–style time picker (wheel flyout, ✓/✕ footer) — see
    # `TimePicker`.
    def time_picker(id : String, value : Time, format : String = "%H:%M:%S",
                    &on_change : Time ->) : Response
      add(TimePicker.new(id, value, format, &on_change))
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
      Grid.new(id).show(self, &block)
    end

    # Hierarchical list; see `TreeView`.
    def tree_view(id : String, &block : TreeView ->) : Nil
      TreeView.new(id).show(self, &block)
    end

    # Header + body table; see `Table`.
    def table(id : String, headers : Array(String),
              fractions : Array(Float64)? = nil, &block : Grid ->) : Nil
      Table.new(id, headers, fractions).show(self, &block)
    end

    # GTK TreeView-style model/view table; see `TableView`. The block
    # configures columns before the table lays out, the return value
    # carries the selection for post-frame queries.
    def table_view(id : String, store : ListStore,
                   &block : TableView ->) : TableView
      tv = TableView.new(id, store)
      yield tv
      tv.show(self)
      tv
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
      # parents keep their flow direction — an up-flowing parent gets a
      # bottom_up cell (#child_ui inheritance).
      if @layout.horizontal?
        cell = child_ui(rect, layout: Layout.left_to_right)
        cell.seed_row_height(rect.height)
      else
        cell = child_ui(rect)
      end
      cell.v_overflow = false
      cell.exact_cell = rect
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
    # mint ids under the scope's id, not the parent's counter). In an
    # up-flowing region the scope covers the space ABOVE the cursor and
    # the flow continues above it (see #remaining_rect/#advance_flow_past).
    def scope(&block : Ui ->) : self
      child = child_ui(remaining_rect)
      yield child
      @min_rect = @min_rect.union(child.min_rect)
      @cursor = advance_flow_past(child.min_rect)
      self
    end

    # rendering_direction entry point (dialogue mode): run the block in
    # a child region whose widgets flow `:up` — the first widget is
    # laid out at the region's bottom edge, the next one above it, and
    # so on — or `:down` (the default everywhere). Architectural: any
    # widget allocated through the child Ui flips (labels, buttons,
    # frames, rows, scopes) because they all place themselves via
    # #allocate_space. Afterwards the parent flow continues past the
    # block's bounding box in the parent's own direction.
    def with_rendering_direction(direction : Symbol, &block : Ui ->) : self
      layout = direction == :up ? Layout.bottom_up : Layout.top_down
      child = child_ui(remaining_rect, layout: layout)
      yield child
      @min_rect = @min_rect.union(child.min_rect)
      @cursor = advance_flow_past(child.min_rect)
      self
    end

    # The space left in this region after the cursor, in the region's
    # own flow direction (below the cursor for :down flows, above it
    # for :up) — what a child block (#scope, #enabled,
    # #with_rendering_direction) lays out into.
    private def remaining_rect : Rect
      if @layout.bottom_up?
        Rect.new(Pos2.new(@cursor.x, @max_rect.min.y),
          Pos2.new(@max_rect.right, @cursor.y))
      else
        Rect.new(@cursor, Pos2.new(@max_rect.right, @max_rect.bottom))
      end
    end

    # Where this region's flow continues after a child block's
    # bounding box (below it for :down flows, above it for :up).
    private def advance_flow_past(child_rect : Rect) : Pos2
      if @layout.bottom_up?
        Pos2.new(@max_rect.min.x,
          child_rect.top - style.spacing.item_spacing.y)
      else
        Pos2.new(@max_rect.min.x,
          child_rect.bottom + style.spacing.item_spacing.y)
      end
    end

    # egui `ui.columns(n)` — split the remaining width into `n` equal
    # columns; the block receives one Ui per column. In an up-flowing
    # region the columns hug the flow line from above and the flow
    # continues above the tallest one.
    def columns(n : Int32, &block : Array(Ui) ->) : Nil
      spacing = style.spacing.item_spacing.x
      gap_total = spacing * (n - 1)
      col_w = {(available_width - gap_total) / {n, 1}.max, 1.0}.max
      height = available_height
      cols = (0...n).map do |i|
        x = @cursor.x + i * (col_w + spacing)
        if @layout.bottom_up?
          child_ui(Rect.new(Pos2.new(x, @cursor.y - height),
            Pos2.new(x + col_w, @cursor.y)))
        else
          child_ui(Rect.from_min_size(Pos2.new(x, @cursor.y),
            Vec2.new(col_w, height)))
        end
      end
      yield cols
      cols.each { |c| @min_rect = @min_rect.union(c.min_rect) }
      @cursor = if @layout.bottom_up?
        Pos2.new(@max_rect.min.x,
          cols.map(&.min_rect.top).min - style.spacing.item_spacing.y)
      else
        Pos2.new(@max_rect.min.x,
          cols.map(&.min_rect.bottom).max + style.spacing.item_spacing.y)
      end
    end

    # egui `ui.enabled(flag, |ui| …)` — gray-out + interaction-block a
    # region. Contents ALWAYS render through a child Ui so widget ids
    # stay stable when the flag flips (interaction state must survive
    # disable/enable cycles). While disabled every Response comes back
    # dead and a translucent scrim is back-painted over the region —
    # except inside menu popups, where rows gray out through muted text
    # instead (a scrim band over the menu frame reads as black).
    def enabled(flag : Bool, &block : Ui ->) : Nil
      scrim_index = painter.add_noop
      child = child_ui(remaining_rect)

      if flag
        yield child
      else
        @ctx.memory.push_disabled
        yield child
        @ctx.memory.pop_disabled
      end

      @min_rect = @min_rect.union(child.min_rect)
      @cursor = advance_flow_past(child.min_rect)
      return if flag
      # Menu rows mute their own text when disabled (menu_item_impl,
      # restylable via the `menu.item:disabled` state layer): a
      # panel_fill band over the menu frame reads as a black
      # rectangle, not as "grayed out".
      return if @menu_popup_key
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
      elsif @layout.bottom_up?
        Vec2.new({@max_rect.right - @cursor.x, 0.0}.max,
          {@cursor.y - @max_rect.min.y, 0.0}.max)
      else
        Vec2.new(@max_rect.right - @cursor.x, @max_rect.bottom - @cursor.y)
      end
    end

    def available_width : Float64
      {@max_rect.right - @cursor.x, 0.0}.max
    end

    def available_height : Float64
      if @layout.bottom_up?
        {@cursor.y - @max_rect.min.y, 0.0}.max
      else
        {@max_rect.bottom - @cursor.y, 0.0}.max
      end
    end

    # `ui.box` — THE generic container ("div"): one entry point over
    # the shared core that #scope/#frame/#horizontal specialize.
    # `direction` picks the children's flow (`:column` — the default —
    # like #scope, `:row` like #horizontal, wrap included), `style_class`
    # runs the children under a style scope (#with_style_scope —
    # `box(style_class: "card")` styles everything inside under
    # "card.*" in ECSS), and fill/stroke/rounding/margin paint chrome
    # under the contents (the #frame trick; margin defaults to the
    # window padding only when chrome is requested, else zero — a
    # plain div has no padding). `stroke_width` is a scalar or a
    # per-side `StyleBox` (`StyleBox.new(top: 1, left: 3)` — CSS
    # `border-width`), `stroke_sides` additionally carries per-side
    # colors (usually resolved from style keys by
    # `StyleVars#stroke_sides?`). `corners` carries the per-corner
    # CSS `border-radius: a b c d` shorthand (nil = uniform
    # `rounding`). `appear`/`appear_delay` override the
    # `appear:`/`appear-delay:` style keys with a named transition
    # played when the box first shows up (see AppearAnims). Returns the
    # outer rect.
    def box(direction : Symbol = :column, wrap : Bool = true,
            fill : Color32 | Gradient? = nil, stroke : Color32? = nil,
            rounding : Float64 = 6.0, margin : Vec2? = nil,
            stroke_width : Float64 | StyleBox = 1.0,
            style_class : String? = nil,
            stroke_sides : StrokeSides? = nil,
            corners : CornerRadii? = nil,
            appear : String | Symbol? = nil,
            appear_delay : Float64? = nil,
            position : Symbol? = nil,
            top : Float64 | Int32 | String? = nil,
            right : Float64 | Int32 | String? = nil,
            bottom : Float64 | Int32 | String? = nil,
            left : Float64 | Int32 | String? = nil,
            z : Int32? = nil,
            &block : Ui ->) : Rect
      sides = stroke_sides ||
              (sw = stroke_width.as?(StyleBox)) && stroke.try do |c|
                StrokeSides.new(
                  SideStroke.new(sw.top, c),
                  SideStroke.new(sw.right, c),
                  SideStroke.new(sw.bottom, c),
                  SideStroke.new(sw.left, c))
              end
      # `fill` may be a full CSS-like gradient (`<box fill="linear-
      # gradient(…)">` / `#box(fill: …)`): it rides the RectCmd's
      # gradient slot, the flat fill stays nil.
      grad = fill.as?(Gradient)
      flat_fill = fill.as?(Color32)
      painted = flat_fill || grad || stroke || sides
      m = margin || (painted ? style.spacing.window_padding : Vec2.new(0.0, 0.0))
      # CSS `position` (see #box_positioning): `absolute`/`fixed` take
      # the box out of the flow entirely (#placed_box); `relative`
      # shifts the in-flow rect (the `rel` offset threaded through the
      # child-rect sites below, space still reserved — siblings never
      # move). Values come from the explicit arguments over the box's
      # class chain, so `ui.box(style_class: "hud")` positions straight
      # from an ECSS `.hud { position: fixed; top: 10 }` rule — and
      # `ui.div` forwards the inline `style:` spellings the same way.
      positioning = box_positioning(style_class, position, top, right,
        bottom, left, z)
      if positioning.is_a?(BoxPlacement)
        return placed_box(positioning, direction, wrap, style_class,
          flat_fill, grad, stroke, sides, rounding, corners, m,
          stroke_width, &block)
      end
      rel = positioning || Vec2.zero
      bg_index = painter.add_noop
      # Rounded-clip bracket (see Painter#clip_apply): everything the
      # subtree paints is re-clipped to the box's ROUNDED outer rect
      # once it exists — scrolled/nested content cannot bleed past the
      # curved corners. Taken after the chrome slot so the background
      # itself (which paints the shape) is not re-clipped.
      clip_from = painter.clip_mark
      row = direction == :row

      # A column box inline in a HORIZONTAL row participates in the
      # row's line wrap (#wrap_x) like any widget: a box cannot know its
      # natural width before its content runs, so the break decision
      # uses the width measured last frame
      # (Memory#inline_box_widths, refreshed in the tail below) — when
      # it does not fit the remainder but fits a fresh line, break the
      # line BEFORE laying the content out (the same break as the wrap
      # branch of #allocate_space / #end_line).
      inline_row = @layout.horizontal? && !row
      inline_id : Id? = nil
      if inline_row
        inline_id = next_widget_id
        if (nat = @ctx.memory.inline_box_widths[inline_id]?)
          remaining = @max_rect.right - @cursor.x
          if @wrap_x && @cursor.x > @max_rect.min.x && nat > remaining &&
             nat <= @max_rect.width + style.spacing.item_spacing.x
            step = @row_h + style.spacing.item_spacing.y
            @cursor = Pos2.new(@max_rect.min.x,
              @cursor.y + (@cross_up ? -step : step))
            @row_h = 0.0
          end
        end
      end
      w = if inline_row
        # Measure against the FULL line width — the same rule a
        # wrap-capable label wraps by (its `wrap_base`, see Label#ui):
        # a sliver-bounded region would word-break the content and the
        # cache below would record the BROKEN width as "natural",
        # freezing the box out of the wrap decision (the wrapping-row
        # regression: a chip that did not fit stayed a squeezed
        # multi-line column forever). Content that fits the remainder
        # renders identically — only the wrap bound widens.
        {@max_rect.width - 2 * m.x, 0.0}.max
      else
        {@max_rect.right - @cursor.x - 2 * m.x, 0.0}.max
      end
      child =
        if @layout.bottom_up?
          if row
            # Up flow: the row hugs the flow line from ABOVE (#horizontal)
            row_ui = child_ui(Rect.new(
              Pos2.new(@cursor.x + m.x + rel.x, @max_rect.min.y + rel.y),
              Pos2.new(@cursor.x + m.x + w, @cursor.y - m.y)),
              layout: Layout.left_to_right)
            row_ui.cross_up = true
            row_ui.cursor = Pos2.new(@cursor.x + m.x + rel.x, @cursor.y - m.y + rel.y)
            row_ui
          else
            child_ui(Rect.new(
              Pos2.new(@cursor.x + m.x + rel.x, @cursor.y - m.y - 1e6 + rel.y),
              Pos2.new(@cursor.x + m.x + w, @cursor.y - m.y)))
          end
        else
          # A row inside a HORIZONTAL parent is a line-break block
          # (#horizontal): start on a fresh full-width line below.
          origin = if row && @layout.horizontal?
            Pos2.new(@max_rect.min.x,
              @cursor.y + @row_h + style.spacing.item_spacing.y)
          else
            @cursor
          end
          child_ui(Rect.from_min_size(origin + m + rel, Vec2.new(w, 1e6)),
            id: inline_id,
            layout: row ? Layout.left_to_right
              : (@layout.bottom_up? ? Layout.bottom_up : Layout.top_down))
        end

      # A `relative` box is the containing block for its `absolute`
      # descendants (CSS). The box's final rect exists only after the
      # children run, so the block rides the same settle scheme as
      # the out-of-flow branch: last frame's measured size under a
      # stable id (#box_pos_id); the width comes from the definite
      # flow region. `positioning` non-nil ⇒ relative here (the
      # absolute/fixed cases returned into #placed_box already).
      box_pos_id : Id? = nil
      if positioning
        box_pos_id = next_widget_id
        last_h = @ctx.memory.layer_sizes[box_pos_id]?.try(&.y) ||
                 Overlay::ESTIMATE.y
        child.pos_context = Rect.from_min_size(child.max_rect.min - m,
          Vec2.new(child.max_rect.width + 2 * m.x, last_h))
        @ctx.memory.use_id(box_pos_id)
      end

      # Appear transition (plans/NATIVE_HTML_DEMO.md §3.2): the whole
      # subtree — children and the back-patched chrome — paints through
      # a painter transform while the run plays. The box's rect (the
      # pivot) exists only after the children have run, so the frame is
      # pushed with a deferred pivot and popped with `outer`'s center.
      xf = appear_transform(child, style_class, appear, appear_delay)
      painter.push_transform(nil, xf[:sx], xf[:sy], xf[:dx], xf[:dy],
        xf[:opacity]) if xf
      outer_rect : Rect? = nil
      begin
        if row
          child.wrap_x = wrap
          # Assume something interactive on a row so short widgets share
          # a common center line (#horizontal's seeding).
          child.seed_row_height(style.spacing.interact_size.y)
        end
        if (sc = style_class)
          child.with_style_scope(sc) { |c| yield c }
        else
          yield child
        end

        outer = Rect.new(child.min_rect.min - m, child.min_rect.max + m)
        if inline_row
          # Inline shrink-to-fit: instead of the block fill (expanding
          # to max_rect's right edge — a vertical-flow contract, kept in
          # the else branch) the box hugs its content and flows along
          # the line like any row widget, with the same band
          # bookkeeping as #allocate_space's horizontal branch (row
          # height tracker, full-band min_rect, cursor pinned at the far
          # edge).
          cid = inline_id.not_nil!
          # Natural-width cache refresh: the region above is the FULL
          # line width, so the measurement is the box's natural width
          # (a box wider than a whole line measured its wrapped extent
          # — it never fits a fresh line, and the break guard leaves
          # it on the current line, wrapped, like any oversized
          # widget).
          @ctx.memory.inline_box_widths[cid] = outer.width
          @row_h = {@row_h, outer.height}.max
          max_x = {@cursor.x + outer.width, @max_rect.right}.min
          if @cross_up
            frame_top = @v_overflow ? @cursor.y - @row_h
                                    : {@cursor.y - @row_h, @max_rect.min.y}.max
            @min_rect = @min_rect.union(
              Rect.new(Pos2.new(@cursor.x, {frame_top, @cursor.y}.min),
                Pos2.new(max_x, @cursor.y)))
          else
            frame_bottom = @v_overflow ? @cursor.y + @row_h
                                       : {@cursor.y + @row_h, @max_rect.bottom}.min
            @min_rect = @min_rect.union(
              Rect.new(@cursor, Pos2.new(max_x, {frame_bottom, @cursor.y}.max)))
          end
          @cursor = Pos2.new(
            {@cursor.x + outer.width + style.spacing.item_spacing.x,
             @max_rect.right}.min, @cursor.y)
        else
          # `relative` shifts the flow slot (`rel`): the clamp keeps a
          # plain box from starting left/up of its slot, so it must
          # compare against the SHIFTED slot, not the raw cursor —
          # otherwise the clamp eats the shift.
          slot = Pos2.new(@cursor.x + rel.x, @cursor.y + rel.y)
          outer = Rect.new(
            Pos2.new({outer.min.x, slot.x}.min, {outer.min.y, slot.y}.min),
            Pos2.new({outer.max.x, @max_rect.right}.max, outer.max.y))
          min_rect = @min_rect.union(outer)
          @cursor = @layout.advance(@cursor, outer.size,
            style.spacing.item_spacing)
          @min_rect = min_rect
        end
        @row_h = 0.0 if row && @layout.horizontal?
        # The relative box's measured size feeds next frame's
        # containing block (the settle scheme above).
        @ctx.memory.layer_sizes[box_pos_id] = outer.size if box_pos_id

        if painted
          painter.set(bg_index,
            RectCmd.new(painter.clip, outer, rounding, flat_fill, stroke,
              stroke_width.as?(Float64) || 1.0, nil, sides, corners,
              gradient: grad))
        end
        outer_rect = outer
      ensure
        painter.pop_transform(outer_rect.try(&.center) || @cursor) if xf
      end
      # A non-zero border radius clips the subtree to the rounded
      # shape (engine-level `overflow: hidden` semantics — any nested
      # element, scroll content included, stays inside the curve).
      radii = corners || CornerRadii.uniform(rounding)
      painter.clip_apply(clip_from, outer_rect.not_nil!, radii) if radii.max > 0.0
      outer_rect.not_nil!
    end

    # Resolve and drive the box's appear transition (see AppearAnims):
    # the explicit `appear`/`appear_delay` arguments beat the cascade,
    # the cascade resolves the box's own class rule over the global
    # "*" rule (a theme-wide default). Returns the transform to paint
    # the subtree with, nil when there is nothing to play. The run is
    # keyed by the box's child-Ui id and marked used so end-frame
    # pruning keeps it while the box is emitted (a re-appearance after
    # the box was gone replays).
    private def appear_transform(child : Ui, style_class : String?,
                                 appear : String | Symbol?,
                                 appear_delay : Float64?) : NamedTuple(sx: Float64, sy: Float64,
                                                                        dx: Float64, dy: Float64,
                                                                        opacity: Float64)?
      return nil if @ctx.reduced_motion?
      vars : StyleVars? = nil
      if appear.nil?
        paths = ["*"] # the theme-global default, least specific
        paths << style_class if style_class
        vars = @ctx.stylesheet.resolve_chain(paths)
        name = vars.str?("appear")
      else
        name = appear.to_s
      end
      return nil if name.nil? || name == "none"
      kind = AppearAnims.kind?(name)
      return nil unless kind
      delay = appear_delay || (vars ? AppearAnims.delay_from(vars) : 0.0)
      xf = @ctx.memory.appear_anims.drive(child.id, kind, delay,
        @ctx.input.time)
      @ctx.memory.use_id(child.id)
      @ctx.request_repaint if xf
      xf
    end

    # egui `Frame::show` — a padded, painted panel around a block of
    # contents: #box with column flow and the window padding default.
    def frame(fill : Color32? = nil, stroke : Color32? = nil,
              rounding : Float64 = 6.0, margin : Vec2? = nil,
              stroke_width : Float64 | StyleBox = 1.0,
              stroke_sides : StrokeSides? = nil, &block : Ui ->) : Rect
      box(:column, fill: fill, stroke: stroke, rounding: rounding,
        margin: margin || style.spacing.window_padding,
        stroke_width: stroke_width, stroke_sides: stroke_sides, &block)
    end

    # egui `ui.horizontal(|ui| …)`: a child Ui laying out left→right on
    # the rest of the current line; afterwards the parent cursor jumps
    # below the row's bounding box (like upstream's single-row shortcut).
    # Built through #child_ui so the row inherits the parent's layer and
    # clip rect — a horizontal row inside a window/scroll area must stay
    # in that layer's z-order and viewport clip.
    # egui `ui.horizontal` — a left-to-right row. WRAPS by default
    # (CSS `flex-wrap: wrap`): a widget that cannot fit the remaining
    # row width breaks onto a new line instead of collapsing at the
    # region edge — the mobile-safe default. `wrap: false` restores
    # the single-line behavior (fixed toolbars that prefer clipping).
    #
    # Inside a HORIZONTAL parent the row is a line-break block: it
    # starts on a fresh full-width line of the parent (its own width
    # is only known after the content runs — the parent's remaining
    # sliver must not cramp it) and the parent's flow continues below.
    def horizontal(wrap : Bool = true, &block : Ui ->) : self
      row_rect = if @layout.horizontal?
        Pos2.new(@max_rect.min.x,
          @cursor.y + @row_h + style.spacing.item_spacing.y)
      else
        @cursor
      end
      if @layout.bottom_up?
        # Up flow: the row hugs the flow line from ABOVE — the region
        # is the remaining space above the cursor, the row's own cursor
        # starts on the line, and the row band grows upward (#cross_up)
        # so it never overlaps the widgets already rendered below.
        row = child_ui(Rect.new(
          Pos2.new(@cursor.x, @max_rect.min.y),
          Pos2.new(@max_rect.right, @cursor.y)),
          layout: Layout.left_to_right)
        row.wrap_x = wrap
        row.cross_up = true
        row.seed_row_height(style.spacing.interact_size.y)
        row.cursor = Pos2.new(@cursor.x, @cursor.y)
        yield row
        @min_rect = @min_rect.union(row.min_rect)
        @cursor = Pos2.new(@max_rect.min.x,
          row.min_rect.top - style.spacing.item_spacing.y)
        return self
      end
      row = child_ui(
        Rect.new(row_rect, Pos2.new(@max_rect.right, @max_rect.bottom)),
        layout: Layout.left_to_right)
      row.wrap_x = wrap
      # Upstream seeds the row at `interact_size.y` ("assume there will
      # be something interactive on the horizontal layout") so short
      # widgets share a common center line before anything tall grows
      # the row — and a row of short widgets keeps a sane height.
      row.seed_row_height(style.spacing.interact_size.y)
      yield row
      @min_rect = @min_rect.union(row.min_rect)
      @cursor = Pos2.new(@max_rect.min.x,
        row.min_rect.bottom + style.spacing.item_spacing.y)
      # A horizontal parent continues on a fresh line below the row
      # block — its line-height tracker starts over.
      @row_h = 0.0 if @layout.horizontal?
      self
    end

    # The out-of-flow branch of #box (`position: absolute|fixed`), CSS
    # semantics: the cursor does not advance, the parent's bounds do
    # not grow — the content lays out ON TOP at the rect computed from
    # the offsets against the containing block (`fixed` → the
    # viewport, `absolute` → Ui#pos_context, the nearest positioned
    # ancestor). Offsets follow CSS per axis: BOTH sides set → stretch
    # between them; only `left`/`top` → pin the near edge (content
    # hugs its natural size below/right of it); neither → the static
    # position (the flow cursor's coordinate on that axis). One
    # deviation from retained-mode CSS, shared with Overlay: pinning
    # `right`/`bottom` alone needs the box's natural size BEFORE the
    # content runs, so it anchors on last frame's measured size
    # (Memory#layer_sizes) and settles the frame after the first
    # measure — the estimate is `Overlay::ESTIMATE`.
    #
    # `z` (argument or the class rule's `z` key) lifts the box into an
    # explicit layer, exactly like Overlay: later paint, stronger
    # hit-test. The content's paint scope (style_class) behaves as in
    # any box. The parent's scroll extent does NOT include the box
    # (fixed content ignores scroll, like CSS).
    private def placed_box(placement : BoxPlacement, direction : Symbol,
                           wrap : Bool, style_class : String?,
                           flat_fill : Color32?,
                           grad : Gradient?, stroke : Color32?,
                           sides : StrokeSides?, rounding : Float64,
                           corners : CornerRadii?, m : Vec2,
                           stroke_width : Float64 | StyleBox,
                           &block : Ui ->) : Rect
      ctx = @ctx
      ctx.memory.use_id(placement.id)
      size = ctx.memory.layer_sizes[placement.id]? || Overlay::ESTIMATE

      cb = placement.containing
      x, x_edge =
        if (l = placement.left) && (r = placement.right)
          {cb.min.x + l, cb.max.x - r}
        elsif (l = placement.left)
          {cb.min.x + l, cb.max.x}
        elsif (r = placement.right)
          {cb.max.x - r - size.x, cb.max.x - r}
        else
          {@cursor.x, cb.max.x}
        end
      y, y_edge =
        if (t = placement.top) && (b = placement.bottom)
          {cb.min.y + t, cb.max.y - b}
        elsif (t = placement.top)
          {cb.min.y + t, cb.max.y}
        elsif (b = placement.bottom)
          {cb.max.y - b - size.y, cb.max.y - b}
        else
          {@cursor.y, cb.max.y}
        end
      # The pinned point is the OUTER rect's top-left; the content
      # region insets by the chrome margin exactly like the normal box
      # path (#box lays content at origin + m and wraps the chrome
      # around it), so a right/bottom-pinned box settles precisely on
      # its offsets. Stretched axes bound the content; hugged axes
      # stay generous downward/rightward.
      stretch_x = !!(placement.left && placement.right)
      stretch_y = !!(placement.top && placement.bottom)
      content_min = Pos2.new(x + m.x, y + m.y)
      content_w = {x_edge - m.x - content_min.x, 1.0}.max
      content_h = stretch_y ? {y_edge - m.y - content_min.y, 1.0}.max : 1e6

      layer = placement.z ?
        LayerId.new(@layer.order, placement.id, z: placement.z.not_nil!) : @layer
      child = child_ui(Rect.from_min_size(content_min,
        Vec2.new(content_w, content_h)),
        layout: direction == :row ? Layout.left_to_right : nil)
      child.layer = layer
      # The positioned box is the containing block for ITS absolute
      # descendants. The final rect exists only after the content
      # runs, so the block rides the same settle scheme as the
      # right/bottom pinning — last frame's measured size — while a
      # stretched axis is definite right away (the offsets give it).
      pc_size = Vec2.new(stretch_x ? x_edge - x : size.x,
                         stretch_y ? y_edge - y : size.y)
      child.pos_context = Rect.from_min_size(Pos2.new(x, y), pc_size)
      child.wrap_x = wrap if direction == :row

      # The chrome noop must be recorded INSIDE the box's layer (the
      # painter is global state, the command's layer is fixed at add
      # time): switch around the block like Overlay/#window do.
      painter = ctx.painter
      prev_layer = painter.layer
      prev_clip = painter.clip
      painter.layer = layer.z
      painter.clip = @clip
      bg_index = painter.add_noop
      clip_from = painter.clip_mark
      begin
        if (sc = style_class)
          child.with_style_scope(sc) { |c| yield c }
        else
          yield child
        end
      ensure
        painter.layer = prev_layer
        painter.clip = prev_clip
      end

      outer = Rect.new(child.min_rect.min - m, child.min_rect.max + m)
      # Both offsets on an axis STRETCH the box to span them (CSS
      # width/height from the offsets) — content hugs, the box (and
      # its paint) spans the full stretched rect.
      if placement.left && placement.right
        outer = Rect.new(outer.min, Pos2.new(x_edge, outer.max.y))
      end
      if placement.top && placement.bottom
        outer = Rect.new(outer.min, Pos2.new(outer.max.x, y_edge))
      end
      painted = flat_fill || grad || stroke || sides
      if painted
        painter.set(bg_index,
          RectCmd.new(painter.clip, outer, rounding, flat_fill, stroke,
            stroke_width.as?(Float64) || 1.0, nil, sides, corners,
            gradient: grad))
      end
      # Same rounded-subtree clip as #box (the absolute variant's
      # children ride `layer`; the mark recorded it).
      radii = corners || CornerRadii.uniform(rounding)
      painter.clip_apply(clip_from, outer, radii) if radii.max > 0.0
      ctx.memory.layer_sizes[placement.id] = outer.size
      outer
    end

    # Resolve the box's CSS `position` from the explicit #box arguments
    # over the class chain (the same "*"/class/scoped paths the appear
    # cascade uses — #appear_transform). Returns a BoxPlacement for
    # `absolute`/`fixed` (containing block + resolved offsets + z + the
    # stable id the natural size is remembered under), a Vec2 shift for
    # `relative` (left-right / top-bottom; percent resolves against the
    # containing block — a pragmatic stand-in for CSS's percent-of-own-
    # size, which immediate mode cannot know before the content runs),
    # nil for `static`/unset. Offset spellings: numbers, or strings
    # with units ("10%", "2vw", "1rem") — the inline `style:` forms
    # pass through here as strings.
    private def box_positioning(style_class : String?, position : Symbol?,
                                top : Float64 | Int32 | String?,
                                right : Float64 | Int32 | String?,
                                bottom : Float64 | Int32 | String?,
                                left : Float64 | Int32 | String?,
                                z : Int32?) : BoxPlacement | Vec2 | Nil
      paths = ["*"]
      if (sc = style_class)
        paths << sc
        paths << "#{@style_scope}.#{sc}" if @style_scope
      elsif (scope = @style_scope)
        paths << scope
      end
      vars = @ctx.stylesheet.resolve_chain(paths)
      pos = position.try(&.to_s) || vars.str?("position")
      return nil unless {"relative", "absolute", "fixed"}.includes?(pos)

      viewport = @ctx.input.screen_rect
      base = pos == "fixed" ? viewport : (@pos_context || viewport)
      mk_off = ->(explicit : Float64 | Int32 | String?, key : String, axis : Symbol) {
        case e = explicit
        when Float64 then e
        when Int32   then e.to_f64
        when String
          (l = StyleLength.parse?(e)) ? l.resolve_in(base, @ctx, axis) : e.to_f64?
        when Nil then vars.length_px_in?(key, base, @ctx, axis)
        end
      }
      top_px = mk_off.call(top, "top", :y)
      right_px = mk_off.call(right, "right", :x)
      bottom_px = mk_off.call(bottom, "bottom", :y)
      left_px = mk_off.call(left, "left", :x)

      if pos == "relative"
        Vec2.new((left_px || 0.0) - (right_px || 0.0),
          (top_px || 0.0) - (bottom_px || 0.0))
      else
        lift = z || vars.f64?("z").try(&.round.to_i)
        BoxPlacement.new(base, top_px, right_px, bottom_px, left_px,
          lift, next_widget_id)
      end
    end
  end

  # A `position: absolute|fixed` box's resolved placement (the
  # #box_positioning output Ui#box's out-of-flow branch consumes):
  # the containing block, the four side offsets in logical points
  # (nil = auto → static position on that axis), the explicit layer
  # lift and the stable id the box's natural size is remembered under
  # (Memory#layer_sizes — the `right:`/`bottom:`-only anchoring).
  struct BoxPlacement
    getter containing : Rect
    getter top : Float64?
    getter right : Float64?
    getter bottom : Float64?
    getter left : Float64?
    getter z : Int32?
    getter id : Id

    def initialize(@containing : Rect, @top : Float64?, @right : Float64?,
                   @bottom : Float64?, @left : Float64?, @z : Int32?,
                   @id : Id)
    end
  end
end
