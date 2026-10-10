# TableView — the GTK TreeView/ListStore pair, ported to immediate
# mode. The MODEL (`ListStore`) owns typed rows; the VIEW (`TableView`)
# renders a windowed slice of them through a ScrollArea viewport.
#
#   store = Egui::ListStore.new(:string, :int)
#   store.append("gcc", 12)
#   tv = Egui::TableView.new("pkgs", store)
#   tv.column("Package", 0, fraction: 0.7)
#   tv.column("Size", 1, align: :right)
#   tv.show(ui)
#
# Like GtkTreeView the view is virtualized (only visible rows lay
# out), columns are click-sorted (GtkTreeSortable lives on the store)
# and drag-resized, and selection is a first-class object with
# :single/:multiple modes (Ctrl toggles, Shift ranges, arrows walk,
# Enter activates).

module Egui
  # GtkListStore + GtkTreeSortable + GtkTreeModelFilter in one: rows
  # live in INSERTION order; sorting/filtering never move them, they
  # only change the DISPLAY mapping (`display_row`) — so indices into
  # the model stay valid across a sort, the row stability GTK needs
  # GtkTreeRowReference for comes for free.
  class ListStore
    alias Value = String | Int32 | Float64 | Bool

    getter column_types : Array(Symbol)
    # Bumped on every mutation (rows, sort, filter) — the display
    # mapping rebuilds when it lags behind.
    getter version : Int32 = 0

    @rows = [] of Array(Value)
    @display = [] of Int32
    @display_version = -1
    @sort_col : Int32? = nil
    @sort_dir : Symbol = :ascending
    @sort_funcs = {} of Int32 => Proc(Int32, Int32, Int32)
    @filter : (Int32 -> Bool)? = nil

    def initialize(*types : Symbol)
      initialize(types.to_a)
    end

    def initialize(types : Array(Symbol))
      raise ArgumentError.new("ListStore needs at least one column") if types.empty?
      types.each do |t|
        unless {:string, :int, :float, :bool}.includes?(t)
          raise ArgumentError.new(
            "unknown column type #{t} (need :string/:int/:float/:bool)")
        end
      end
      @column_types = types
    end

    # --- GtkListStore row CRUD ------------------------------------------

    # Append a full row; returns the new row's index (insertion order).
    def append(*values : Value) : Int32
      ary = values.to_a
      raise ArgumentError.new(
        "row has #{ary.size} values, store has #{@column_types.size} columns"
      ) unless ary.size == @column_types.size
      @rows << coerced_row(ary)
      bump
      @rows.size - 1
    end

    def insert(pos : Int32, *values : Value) : Int32
      ary = values.to_a
      raise ArgumentError.new(
        "row has #{ary.size} values, store has #{@column_types.size} columns"
      ) unless ary.size == @column_types.size
      pos = pos.clamp(0, @rows.size)
      @rows.insert(pos, coerced_row(ary))
      bump
      pos
    end

    # A typed copy of `ary` with every value checked/widened against
    # its column's declared type.
    private def coerced_row(ary : Array) : Array(Value)
      row = Array(Value).new(@column_types.size)
      @column_types.each_with_index do |_t, c|
        row << coerce(c, ary[c].as(Value))
      end
      row
    end

    def set(row : Int32, col : Int32, value : Value) : Nil
      @rows[row][col] = coerce(col, value)
      bump
    end

    def get(row : Int32, col : Int32) : Value
      @rows[row][col]
    end

    def get_string(row : Int32, col : Int32) : String
      get(row, col).to_s
    end

    def get_int(row : Int32, col : Int32) : Int32
      case v = get(row, col)
      when Int32   then v
      when Float64 then v.to_i32
      else raise ArgumentError.new("column #{col} is not numeric")
      end
    end

    def get_f64(row : Int32, col : Int32) : Float64
      case v = get(row, col)
      when Int32   then v.to_f64
      when Float64 then v
      else raise ArgumentError.new("column #{col} is not numeric")
      end
    end

    def get_bool(row : Int32, col : Int32) : Bool
      v = get(row, col)
      v.is_a?(Bool) ? v : false
    end

    def remove(row : Int32) : Nil
      @rows.delete_at(row) if row >= 0 && row < @rows.size
      bump
    end

    def clear : Nil
      @rows.clear
      bump
    end

    def row_count : Int32
      @rows.size
    end

    # --- GtkTreeSortable -------------------------------------------------

    # `col == nil` returns to insertion order; `dir` is
    # :ascending/:descending. Clicking a sorted header flips the dir.
    def set_sort_column(col : Int32?, dir : Symbol = :ascending) : Nil
      unless {:ascending, :descending}.includes?(dir)
        raise ArgumentError.new("sort dir must be :ascending/:descending")
      end
      if col && col >= @column_types.size
        raise ArgumentError.new("column #{col} out of range")
      end
      @sort_col = col
      @sort_dir = dir
      bump
    end

    def sort_column : {Int32, Symbol}?
      @sort_col ? {@sort_col.not_nil!, @sort_dir} : nil
    end

    # Custom comparator per column (GTK `gtk_tree_sortable_set_sort_func`):
    # gets MODEL row indices, returns <0 / 0 / >0 like `<=>`. Overrides
    # the type default — the way to get "2 MB < 10 MB" ordering out of
    # a :string column.
    def set_sort_func(col : Int32, &block : Int32, Int32 -> Int32) : Nil
      @sort_funcs[col] = block
      bump
    end

    # --- GtkTreeModelFilter ----------------------------------------------

    # Predicate over MODEL rows; nil shows everything. Filtered-out
    # rows keep their indices and their selection.
    def filter=(pred : (Int32 -> Bool)?) : Nil
      @filter = pred
      bump
    end

    def filter : (Int32 -> Bool)?
      @filter
    end

    # --- display mapping --------------------------------------------------

    def display_count : Int32
      refresh_display
      @display.size
    end

    # The model row shown at display position `i`.
    def display_row(i : Int32) : Int32
      refresh_display
      @display[i]
    end

    # The display position of a model row (nil when filtered out).
    def display_index(row : Int32) : Int32?
      refresh_display
      @display.index(row)
    end

    def each_display_row(&block : Int32 ->) : Nil
      refresh_display
      @display.each { |r| yield r }
    end

    # --- internals ----------------------------------------------------------

    private def bump : Nil
      @version += 1
    end

    private def coerce(col : Int32, value : Value) : Value
      case @column_types[col]
      when :string
        raise ArgumentError.new("column #{col} wants a String") unless value.is_a?(String)
      when :int
        raise ArgumentError.new("column #{col} wants an Int32") unless value.is_a?(Int32)
      when :float
        return value.to_f64 if value.is_a?(Int32)
        raise ArgumentError.new("column #{col} wants a Float64") unless value.is_a?(Float64)
      when :bool
        raise ArgumentError.new("column #{col} wants a Bool") unless value.is_a?(Bool)
      end
      value
    end

    # Rebuild the display mapping when the model changed. The sort is
    # STABLE (index tiebreak) so equal keys keep their relative order —
    # the GTK guarantee the view relies on for predictable rows.
    private def refresh_display : Nil
      return if @display_version == @version
      base = (0...@rows.size).select { |r| @filter.nil? || @filter.not_nil!.call(r) }
      if (sc = @sort_col) && sc < @column_types.size
        keyed = base.each_with_index.map { |r, i| {r, i} }.to_a
        if func = @sort_funcs[sc]?
          keyed.sort! do |(ra, ia), (rb, ib)|
            c = func.call(ra, rb)
            c.zero? ? ia <=> ib : c
          end
        else
          keyed.sort! do |(ra, ia), (rb, ib)|
            c = compare_values(sc, ra, rb)
            c.zero? ? ia <=> ib : c
          end
        end
        base = keyed.map(&.[0])
        base.reverse! if @sort_dir == :descending
      end
      @display = base
      @display_version = @version
    end

    private def compare_values(col : Int32, ra : Int32, rb : Int32) : Int32
      a = @rows[ra][col]
      b = @rows[rb][col]
      if a.is_a?(String) && b.is_a?(String)
        # Case-insensitive (package lists expect "apt" near "APT");
        # #set_sort_func for domain-aware ordering.
        a.downcase <=> b.downcase
      elsif a.is_a?(Bool) && b.is_a?(Bool)
        (a ? 1 : 0) <=> (b ? 1 : 0)
      elsif a.is_a?(Int32) && b.is_a?(Int32)
        a <=> b
      elsif a.is_a?(Float64) && b.is_a?(Float64)
        c = a <=> b
        c ? c.to_i32 : 0
      else
        0
      end
    end
  end

  class TableView
    # One rendered column: where the data comes from (model column),
    # how much space it takes and how cells draw — the
    # GtkTreeViewColumn + GtkCellRendererText pair collapsed into one.
    class Column
      property title : String
      property model_col : Int32
      # Share of the table width before any user resize (fractions
      # normalize to whatever they sum to; nil = equal split).
      property fraction : Float64?
      property min_width : Float64 = 40.0
      # :left / :right / :center (numeric columns want :right).
      property align : Symbol = :left
      property? sortable : Bool = true
      property? resizable : Bool = true
      # Per-row text color (status colors in a package list).
      property color : (Int32 -> Color32)?
      # Value → display text (`1_048_576` → "1.0 MB"); default `to_s`,
      # :bool columns draw a check glyph instead.
      property format : (ListStore::Value -> String)?

      def initialize(@title : String, @model_col : Int32)
      end
    end

    # GtkTreeSelection: which MODEL rows are selected, plus the click
    # modes. `anchor` is the row the last click/arrow landed on — the
    # pivot Shift-ranges grow from.
    class Selection
      property mode : Symbol = :single # :none / :single / :multiple
      getter rows = Set(Int32).new
      property anchor : Int32? = nil

      def selected?(row : Int32) : Bool
        @rows.includes?(row)
      end

      def selected_row : Int32?
        @rows.first?
      end

      def count : Int32
        @rows.size
      end

      def select(row : Int32) : Nil
        return if @mode == :none
        @rows.clear if @mode == :single
        @rows.add(row)
        @anchor = row
      end

      def unselect(row : Int32) : Nil
        @rows.delete(row)
      end

      def clear : Nil
        @rows.clear
      end

      def select_all(count : Int32) : Nil
        return unless @mode == :multiple
        (0...count).each { |r| @rows.add(r) }
      end
    end

    getter store : ListStore
    getter selection : Selection
    # Text shown when the (filtered) store is empty.
    property empty_text : String = "no rows"

    # Child-id salts (UInt64, see Id#child): header cells, resize
    # grips, the body ScrollArea, per-row interacts, saved widths and
    # the focusable body interact.
    private HEADER = 0x1000_u64
    private GRIP = 0x2000_u64
    private BODY = 0x3000_u64
    private ROW = 0x4000_u64
    private WIDTHS = 0x5000_u64
    private FOCUS = 0x9000_u64

    # Vertical padding inside a row band, cell text padding, and the
    # header resize-grip width (px).
    PAD_Y = 3.0
    PAD_X = 6.0
    GRIP_W = 6.0

    @columns = [] of Column
    @on_activate : (Int32 ->)?
    @id : Id

    def initialize(id : String, @store : ListStore)
      @id = Id.from("table_view/#{id}")
      @selection = Selection.new
    end

    # Declare a rendered column; further tweaking goes through the
    # returned Column (`tv.column("Size", 3, align: :right).format = …`).
    def column(title : String, model_col : Int32, *,
               fraction : Float64? = nil, min_width : Float64 = 40.0,
               align : Symbol = :left, sortable : Bool = true,
               resizable : Bool = true) : Column
      col = Column.new(title, model_col)
      col.fraction = fraction
      col.min_width = min_width
      col.align = align
      col.sortable = sortable
      col.resizable = resizable
      @columns << col
      col
    end

    # Double-click / Enter on a row (GTK `row-activated`).
    def on_activate(&block : Int32 ->) : self
      @on_activate = block
      self
    end

    def show(ui : Ui) : Nil
      raise "TableView has no columns" if @columns.empty?
      style = ui.style
      visuals = style.visuals
      memory = ui.ctx.memory
      fs = style.font_size
      width = ui.available_width
      row_h = {fs * Fonts::LINE_H_FACTOR + 2 * PAD_Y,
               style.spacing.interact_size.y}.max
      header_h = {fs * Fonts::LINE_H_FACTOR + 2 * (PAD_Y + 1.0),
                  style.spacing.interact_size.y}.max

      widths = column_widths(memory, width)
      xs = cumulative_xs(widths)

      # --- header band ----------------------------------------------------
      header = ui.allocate_at_least(Vec2.new(width, header_h))
      painter = ui.painter
      painter.rect(header, 0.0, visuals.fade_color(visuals.text_color, 0.07))

      # Cell interacts first, grips after: grips ride ON TOP of the
      # header cells they straddle (the egui top-most-wins order).
      cells = @columns.each_with_index.map do |_col, c|
        Rect.from_min_size(
          Pos2.new(header.left + xs[c], header.top),
          Vec2.new(widths[c], header_h))
      end.to_a
      resps = cells.map_with_index do |cell, c|
        ui.interact(cell, @id.child(HEADER + c.to_u64), Sense.click)
      end

      resps.each_with_index do |resp, c|
        col = @columns[c]
        cell = cells[c]
        painter.rect(cell, 0.0,
          visuals.fade_color(visuals.text_color, 0.10)) if resp.hovered?
        if resp.clicked? && col.sortable?
          cur = @store.sort_column
          if cur && cur[0] == col.model_col && cur[1] == :ascending
            @store.set_sort_column(col.model_col, :descending)
          else
            @store.set_sort_column(col.model_col, :ascending)
          end
          ui.ctx.request_repaint
        end
        avail = cell.width - 2 * PAD_X
        avail -= fs * 0.8 if sort_indicator?(col)
        title = ui.fonts.fit(col.title, fs, avail)
        painter.text(Pos2.new(cell.left + PAD_X, cell.center.y),
          title, fs, visuals.title_color, bold: true)
        draw_sort_arrow(painter, cell, fs, visuals.title_color,
          ascending: @store.sort_column.not_nil![1] == :ascending
        ) if sort_indicator?(col)
        if c > 0
          painter.line(Pos2.new(cell.left, header.top),
            Pos2.new(cell.left, header.bottom), 1.0,
            visuals.fade_color(visuals.text_color, 0.15))
        end
      end
      painter.line(Pos2.new(header.left, header.bottom - 0.5),
        Pos2.new(header.right, header.bottom - 0.5), 1.0,
        visuals.separator_color)

      # --- resize grips -----------------------------------------------------
      (@columns.size - 1).times do |i|
        next unless @columns[i].resizable? && @columns[i + 1].resizable?
        grip = Rect.from_min_size(
          Pos2.new(header.left + xs[i + 1] - GRIP_W / 2.0, header.top),
          Vec2.new(GRIP_W, header_h))
        resp = ui.interact(grip, @id.child(GRIP + i.to_u64), Sense.drag)
        resp.on_hover_and_drag_cursor(CursorIcon::EwResize)
        next unless resp.dragged?
        lo = @columns[i].min_width
        hi = widths[i] + widths[i + 1] - @columns[i + 1].min_width
        new_w = (widths[i] + resp.drag_delta.x).clamp(lo, hi)
        widths[i + 1] += widths[i] - new_w # the neighbor absorbs
        widths[i] = new_w
        persist_widths(memory, widths)
      end

      # --- body --------------------------------------------------------------
      body_id = @id.child(BODY)
      scroll = ScrollArea.new(ui.available_height, id: body_id)
      viewport = scroll.show(ui) do |inner|
        vh = inner.max_rect.height
        origin = inner.max_rect.min
        offset = memory.data.get_vec2(body_id, Vec2.zero)
        n = @store.display_count
        # The full virtual content rect drives the scrollbar and the
        # offset clamp — only the visible slice below paints.
        inner.min_rect = inner.min_rect.union(
          Rect.from_min_size(origin, Vec2.new(width, n * row_h)))

        on_screen = Rect.from_min_size(origin + offset, Vec2.new(width, vh))
        painter.rect(on_screen, 0.0, visuals.panel_fill)

        body_resp = ui.interact(on_screen, @id.child(FOCUS),
          Sense::Click | Sense::Focusable)
        input = ui.ctx.input

        # Keyboard navigation (the GTK list keys): arrows/Home/End walk
        # the anchor row, Shift extends, PageUp/Down jump a viewport,
        # Ctrl+A selects all, Enter activates.
        if body_resp.has_focus? && n > 0
          handle_keys(ui, input, body_id, row_h, vh, offset, n)
        end

        if n.zero?
          text_w = ui.fonts.measure_cached(@empty_text, fs).x
          painter.text(
            Pos2.new(origin.x + {width - text_w, 0.0}.max / 2.0,
              origin.y + offset.y + vh / 2.0),
            @empty_text, fs, visuals.fade_color(visuals.text_color, 0.5))
        end

        first = {((offset.y / row_h).floor - 1).to_i32, 0}.max
        last = (((offset.y + vh) / row_h).ceil + 1).to_i32.clamp(0, n - 1)
        zebra = visuals.fade_color(visuals.text_color, 0.04)
        (first..last).each do |i|
          next if i >= n
          row = @store.display_row(i)
          band = Rect.from_min_size(
            Pos2.new(origin.x, origin.y + i * row_h),
            Vec2.new(width, row_h))
          resp = inner.interact(band, @id.child(ROW + row.to_u64), Sense.click)
          selected = @selection.selected?(row)
          if selected
            fill = resp.hovered? ? visuals.strong_color(visuals.selection_fill) :
                                   visuals.selection_fill
            painter.rect(band, 0.0, fill)
          elsif resp.hovered?
            painter.rect(band, 0.0, visuals.button_hovered)
          elsif i.odd?
            painter.rect(band, 0.0, zebra)
          end
          # The focused table's current row gets a GTK-style outline.
          if body_resp.has_focus? && @selection.anchor == row
            painter.rect(band, 0.0, nil, visuals.selection_fill, 1.0)
          end
          draw_cells(ui, painter, band, row, widths, xs, selected)

          if resp.clicked?
            body_resp.request_focus
            apply_click(row, input)
          end
          if resp.double_clicked?
            body_resp.request_focus
            @on_activate.try(&.call(row))
          end
        end
      end

      # One frame around header + body (GTK's sunken list edge).
      ui.painter.rect(header.union(viewport), 0.0, nil,
        visuals.separator_color, 1.0)
    end

    private def sort_indicator?(col : Column) : Bool
      cur = @store.sort_column
      !cur.nil? && cur[0] == col.model_col
    end

    private def draw_sort_arrow(painter : Painter, cell : Rect, fs : Float64,
                                color : Color32, ascending : Bool) : Nil
      s = fs * 0.22
      cx = cell.right - PAD_X - s
      cy = cell.center.y
      if ascending
        painter.triangle(Pos2.new(cx, cy - s), Pos2.new(cx - s, cy + s * 0.8),
          Pos2.new(cx + s, cy + s * 0.8), color)
      else
        painter.triangle(Pos2.new(cx, cy + s), Pos2.new(cx - s, cy - s * 0.8),
          Pos2.new(cx + s, cy - s * 0.8), color)
      end
    end

    private def draw_cells(ui : Ui, painter : Painter, band : Rect, row : Int32,
                           widths : Array(Float64), xs : Array(Float64),
                           selected : Bool) : Nil
      style = ui.style
      fs = style.font_size
      default = style.visuals.text_color
      @columns.each_with_index do |col, c|
        cell = Rect.from_min_size(
          Pos2.new(band.left + xs[c], band.top),
          Vec2.new(widths[c], band.height))
        value = @store.get(row, col.model_col)
        color = col.color.try(&.call(row)) || default
        if value.is_a?(Bool)
          if value
            icon = Rect.from_min_size(
              Pos2.new(cell.left + PAD_X, cell.center.y - fs * 0.3),
              Vec2.new(fs * 0.6, fs * 0.6))
            Icons.draw(painter, :check, icon, color, 2.5)
          end
          next
        end
        text = col.format.try(&.call(value)) || value.to_s
        text = ui.fonts.fit(text, fs, cell.width - 2 * PAD_X)
        tw = ui.fonts.measure_cached(text, fs).x
        x = case col.align
            when :right  then cell.right - PAD_X - tw
            when :center then cell.left + {cell.width - tw, 0.0}.max / 2.0
            else              cell.left + PAD_X
            end
        # Selected rows take light text: the accent band would swallow
        # the normal (dark-theme dim / light-theme near-black) color.
        painter.text(Pos2.new(x, cell.center.y), text, fs,
          selected ? Color32.rgb(255, 255, 255) : color)
      end
    end

    # --- selection ------------------------------------------------------------

    private def apply_click(row : Int32, input : InputState) : Nil
      sel = @selection
      return if sel.mode == :none
      if sel.mode == :multiple && input.modifiers.ctrl
        sel.selected?(row) ? sel.unselect(row) : sel.select(row)
        sel.anchor = row
      elsif sel.mode == :multiple && input.modifiers.shift
        apos = sel.anchor.try { |a| @store.display_index(a) } ||
               @store.display_index(row) || 0
        bpos = @store.display_index(row) || apos
        ({apos, bpos}.min..{apos, bpos}.max).each do |i|
          sel.rows.add(@store.display_row(i))
        end
        sel.anchor = row
      else
        sel.clear
        sel.select(row)
      end
    end

    # Arrow/Home/End/PageUp/Down move (Shift extends the range from the
    # anchor), Ctrl+A selects everything, Enter activates the anchor
    # row. Every move keeps the walked row on screen by writing the
    # clamped offset straight into the body ScrollArea's state cell.
    private def handle_keys(ui : Ui, input : InputState, body_id : Id,
                            row_h : Float64, vh : Float64, offset : Vec2,
                            n : Int32) : Nil
      ctx = ui.ctx
      anchor = @selection.anchor
      anchor_pos = (anchor.try { |a| @store.display_index(a) } || 0)
        .clamp(0, n - 1)
      multi = @selection.mode == :multiple

      target : Int32? = nil
      case
      when input.key_pressed?(KeyCode::Down) && input.consume_key(KeyCode::Down)
        target = {anchor_pos + 1, n - 1}.min
      when input.key_pressed?(KeyCode::Up) && input.consume_key(KeyCode::Up)
        target = {anchor_pos - 1, 0}.max
      when input.key_pressed?(KeyCode::Home) && input.consume_key(KeyCode::Home)
        target = 0
      when input.key_pressed?(KeyCode::End) && input.consume_key(KeyCode::End)
        target = n - 1
      when input.key_pressed?(KeyCode::PageDown) && input.consume_key(KeyCode::PageDown)
        page = [((vh / row_h).floor.to_i32 - 1), 1].max
        target = {anchor_pos + page, n - 1}.min
      when input.key_pressed?(KeyCode::PageUp) && input.consume_key(KeyCode::PageUp)
        page = [((vh / row_h).floor.to_i32 - 1), 1].max
        target = {anchor_pos - page, 0}.max
      end

      if (pos = target)
        ctx.request_repaint
        if multi && input.modifiers.shift
          ({anchor_pos, pos}.min..{anchor_pos, pos}.max).each do |i|
            @selection.rows.add(@store.display_row(i))
          end
        else
          @selection.clear
          @selection.select(@store.display_row(pos))
        end
        ensure_visible(ctx.memory, body_id, offset, pos * row_h, row_h, vh)
      end

      if multi && input.modifiers.ctrl && input.key_pressed?(KeyCode::A) &&
         input.consume_key(KeyCode::A)
        ctx.request_repaint
        @selection.rows.clear
        @store.each_display_row { |r| @selection.rows.add(r) }
      end

      if input.key_pressed?(KeyCode::Enter) && input.consume_key(KeyCode::Enter) &&
         (row = @selection.selected_row)
        @on_activate.try(&.call(row))
      end
    end

    # Scroll the row at content-y `top` into view (GTK
    # `scroll_to_cell`'s minimal sibling: clamp-only, never centers).
    private def ensure_visible(memory : Memory, body_id : Id, offset : Vec2,
                               top : Float64, row_h : Float64, vh : Float64) : Nil
      off = offset.y
      off = top if top < off
      off = top + row_h - vh if top + row_h > off + vh
      # The content-size cell is only written by the ScrollArea AFTER
      # its block runs; clamp by the total row count instead.
      total = @store.display_count * row_h
      off = off.clamp(0.0, {total - vh, 0.0}.max)
      memory.data.set_vec2(body_id, Vec2.new(offset.x, off)) unless off == offset.y
      memory.use_id(body_id)
    end

    # --- column layout ----------------------------------------------------------

    # X offset of each column's left edge (`xs.size == widths.size`,
    # the last one extends past the table — its width fills the rest).
    private def cumulative_xs(widths : Array(Float64)) : Array(Float64)
      xs = [] of Float64
      x = 0.0
      widths.each { |w| xs << x; x += w }
      xs
    end

    # Saved (dragged) widths when the count matches, else the
    # fraction layout. Either way the result sums to `width`: saved
    # widths are stretched onto the current table width by growing the
    # last column (a plain window resize), or shrunk proportionally
    # when the mins would overflow.
    private def column_widths(memory : Memory, width : Float64) : Array(Float64)
      n = @columns.size
      count_id = @id.child(WIDTHS)
      count = memory.data.get_int(count_id, 0)
      widths : Array(Float64)? = nil
      if count == n
        # Read AND kept alive every frame: a saved layout must survive
        # the frames between drags (IdTypeMap pruning drops unused).
        memory.use_id(count_id)
        widths = (0...n).map { |c|
          w_id = @id.child(WIDTHS + 1_u64 + c.to_u64)
          memory.use_id(w_id)
          memory.data.get_f64(w_id, 0.0)
        }
      end
      if widths.nil?
        fr = @columns.map { |c| c.fraction || 1.0 / n }
        sum = fr.sum
        widths = fr.map { |f| width * f / sum }
      end
      widths = widths.map_with_index { |w, c| {w, @columns[c].min_width}.max }
      slack = width - widths.sum
      if slack != 0.0
        last_min = @columns[n - 1].min_width
        if slack > 0.0 || widths[n - 1] + slack >= last_min
          widths[n - 1] += slack
        else
          widths[n - 1] = last_min
          rest = width - last_min
          rest_sum = widths[0...-1].sum
          if rest_sum > 0.0
            scale = rest / rest_sum
            (0...n - 1).each { |c| widths[c] = widths[c] * scale }
          end
        end
      end
      widths
    end

    # A drag ended: pin the current widths so later frames keep them
    # (and mark the cells used — pruning would otherwise drop them).
    private def persist_widths(memory : Memory, widths : Array(Float64)) : Nil
      count_id = @id.child(WIDTHS)
      memory.data.set_int(count_id, widths.size)
      widths.each_with_index do |w, c|
        memory.data.set_f64(@id.child(WIDTHS + 1_u64 + c.to_u64), w)
      end
      memory.use_id(count_id)
      widths.each_with_index { |_w, c| memory.use_id(@id.child(WIDTHS + 1_u64 + c.to_u64)) }
    end
  end
end
