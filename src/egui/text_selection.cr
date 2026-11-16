# Document-wide text selection — the browser model. Selection is NOT
# owned by a widget: every selectable text region (a Label's, a
# RichLabel's galley) registers itself as a "cell" while it paints, and
# one global gesture in #begin_frame drives a (cell, char) anchor/focus
# pair across them all:
#
#   - press on a cell places the caret (anchor = focus); a press that
#     hits NO cell (or a non-text widget) clears the selection — the
#     browser "click elsewhere" rule, now in ONE place instead of per
#     widget
#   - drag moves the focus through ANY registered cell (nearest-cell
#     fallback when the pointer is between cells), so a selection
#     crosses widget boundaries like in a browser
#   - double-click selects a word, triple-click the whole cell,
#     Shift+click extends the focus
#   - Ctrl/Cmd+C copies, Ctrl/Cmd+A selects all, Escape clears — the
#     hotkeys run while no text editor owns the keyboard (see Focus#
#     clipboard_shortcuts_free?), replacing the old per-label race for
#     #consume_key
#
# Widgets keep painting their own highlight: #range_for hands each cell
# its slice of the global selection as a char range in the cell's
# flattened row text, and the cell paints it through the same
# per-row strip machinery TextEdit uses. Cells from the PREVIOUS frame
# back the gesture (hit-testing needs the complete frame, exactly like
# Memory's prv_* geometry); a cell whose widget stopped rendering stays
# resolvable while the selection references it, and its text survives
# in the endpoint snapshot so Copy still works (the browser keeps
# selecting text scrolled out of view the same way).
#
# Ordering is geometric — caret position for the endpoints, rect
# center for the cells between them — which matches document order for
# flow layouts (reading order: rows top-to-bottom, cells left-to-right
# within a row). Registration order only breaks exact ties.

module Egui
  class TextSelection
    DOUBLE_CLICK_TIME = 0.3
    CLICK_MAX_DIST    = 6.0

    # One selectable text region: the galley a widget laid out plus the
    # geometry needed to map pointer positions onto char offsets in the
    # flattened row text. Built by #register while the widget paints.
    class CellData
      getter id : Id
      getter galley : Galley
      getter fonts : Fonts
      getter resolve : (String?, Bool, Bool) -> Fonts
      getter align : Symbol?
      # Flattened row text ('\n' dropped by layout) — the coordinate
      # space of char offsets, same as the old per-widget selection.
      getter flat : String
      # Copy source: for plain labels the ORIGINAL text ('\n' intact)
      # mapped back through #slice_source; verbatim for widgets whose
      # flat text is already the copy text (RichLabel: markup-stripped).
      getter source : String
      getter? map_newlines : Bool
      # Cumulative char offset of each row start in `flat`.
      getter row_starts : Array(Int32)
      # The widget's interact rect (hit-testing, drag tracking) and the
      # offset from it to the galley origin — a paint-cache replay
      # refreshes the position from Response#rect alone.
      property rect : Rect
      getter content_offset : Vec2
      # Registration sequence — the tie-breaker of the geometric order.
      property seq : Int32 = 0

      def initialize(@id : Id, interact_rect : Rect, content_rect : Rect,
                     @galley : Galley, @fonts : Fonts,
                     @resolve : (String?, Bool, Bool) -> Fonts,
                     @align : Symbol?, @flat : String, @source : String,
                     @map_newlines : Bool)
        @rect = interact_rect
        @content_offset = Vec2.new(
          interact_rect.min.x - content_rect.min.x,
          interact_rect.min.y - content_rect.min.y)
        starts = [] of Int32
        start = 0
        @galley.rows.each do |row|
          starts << start
          start += row.text.size
        end
        @row_starts = starts
      end

      # Where the galley actually paints (interact rect minus padding /
      # alignment slack) — the coordinate space of caret geometry.
      def content_rect : Rect
        Rect.from_min_size(
          Pos2.new(@rect.min.x - @content_offset.x,
            @rect.min.y - @content_offset.y), @galley.size)
      end

      # Horizontal shift paint_galley applies to an aligned row —
      # pointer positions must be mapped through the same shift.
      def align_dx(row : Galley::Row) : Float64
        case @align
        when :center then {@galley.size.x - row.width, 0.0}.max / 2.0
        when :right  then {@galley.size.x - row.width, 0.0}.max
        else              0.0
        end
      end
    end

    # A selection endpoint: the cell's widget id, a char offset in that
    # cell's flat text, and a snapshot of the flat text (Copy still
    # works after the cell's widget stopped rendering).
    struct Pos
      getter id : Id
      getter char : Int32
      getter flat : String

      def initialize(@id : Id, @char : Int32, @flat : String)
      end
    end

    getter anchor : Pos?
    getter focus : Pos?
    @cells : Hash(Id, CellData) = {} of Id => CellData
    @prev : Hash(Id, CellData) = {} of Id => CellData
    @seq = 0
    @dragging = false
    @press_seq = 0
    @last_press_time = -1.0
    @last_press : Pos2? = nil
    @last_press_cell : Id? = nil

    # Non-collapsed selection (the paint-cache opt-out gates on this:
    # every cell must repaint its highlight, while a collapsed caret —
    # a plain click — paints nothing and replays fine).
    def any_selection? : Bool
      a = @anchor
      f = @focus
      !!(a && f && !(a.id == f.id && a.char == f.char))
    end

    def clear : Nil
      @anchor = nil
      @focus = nil
      @dragging = false
    end

    # --- registration (widgets) -------------------------------------------

    # A selectable widget registers while painting for real. Calling
    # twice in a frame (a flex measure pass + the real pass) keeps the
    # LAST registration — it carries the geometry the widget painted.
    def register(id : Id, interact_rect : Rect, content_rect : Rect,
                 galley : Galley, fonts : Fonts,
                 resolve : (String?, Bool, Bool) -> Fonts,
                 align : Symbol?, flat : String, source : String,
                 map_newlines : Bool) : Nil
      cell = CellData.new(id, interact_rect, content_rect, galley,
        fonts, resolve, align, flat, source, map_newlines)
      cell.seq = @seq += 1
      @cells.delete(id)
      @cells[id] = cell
    end

    # A paint-cache replay re-registers the cell from the stored data,
    # refreshing the position through the replayed Response#rect — the
    # gesture keeps hit-testing labels that did not run for real.
    def reregister(id : Id, interact_rect : Rect) : Nil
      cell = @cells[id]? || @prev[id]?
      return unless cell
      cell.rect = interact_rect
      cell.seq = @seq += 1
      @cells.delete(id)
      @cells[id] = cell
    end

    # --- frame driving (Context#begin_frame) ------------------------------

    def begin_frame(input : InputState, memory : Memory) : Nil
      @prev = @cells
      @cells = {} of Id => CellData
      @seq = 0
      # Keep-alive: an endpoint cell whose widget has not re-registered
      # (scrolled out, culled) stays resolvable while the selection
      # references it — geometry for ordering, text for Copy. Painting
      # never sees it: only a cell's own widget asks #range_for(id).
      {@anchor, @focus}.each do |p|
        next unless p
        unless @cells.has_key?(p.not_nil!.id)
          @prev[p.not_nil!.id]?.try { |c| @cells[c.id] = c }
        end
      end
      gesture(input, memory)
      hotkeys(input, memory)
    end

    private def gesture(input : InputState, memory : Memory) : Nil
      return unless pos = input.pointer_pos
      if input.pointer_pressed?
        # A press inside an open popup is a menu row (Copy / Select all)
        # — it must not clear the selection the menu acts on.
        return if memory.popup_rects.any? { |_, r| r.contains?(pos) }
        if (cell = hit_cell(pos, memory))
          char = caret_at(cell, pos)
          # A multi-click continues a series only on the SAME cell
          # (the browser rule) — clicking beside the text and back is
          # two plain clicks, not a double-click, and the word/cell
          # re-selection ("the selection won't dismiss") can't happen.
          now = input.time
          multi = cell.id == @last_press_cell &&
                  (lp = @last_press) &&
                  now - @last_press_time <= DOUBLE_CLICK_TIME &&
                  (pos.x - lp.x).abs <= CLICK_MAX_DIST &&
                  (pos.y - lp.y).abs <= CLICK_MAX_DIST
          @press_seq = multi ? @press_seq + 1 : 1
          @last_press_time = now
          @last_press = pos
          @last_press_cell = cell.id
          if input.modifiers.shift && @anchor && @press_seq == 1
            @focus = Pos.new(cell.id, char, cell.flat)
          elsif @press_seq == 2
            lo, hi = word_range(cell.flat, char)
            @anchor = Pos.new(cell.id, lo, cell.flat)
            @focus = Pos.new(cell.id, hi, cell.flat)
          elsif @press_seq >= 3
            @anchor = Pos.new(cell.id, 0, cell.flat)
            @focus = Pos.new(cell.id, cell.flat.size, cell.flat)
          else
            @anchor = Pos.new(cell.id, char, cell.flat)
            @focus = @anchor.not_nil!
          end
          @dragging = true
        else
          clear
          # A press on nothing ends any click series too: the next
          # quick click on a label is a plain caret, not a word
          # selection riding a stale sequence.
          @press_seq = 0
          @last_press_cell = nil
        end
      elsif @dragging && (input.pointer_down? || input.pointer_released?)
        # The focus follows the pointer through the whole drag,
        # release included (a press/move/release collapsed into ONE
        # frame still extends the selection to the release point) —
        # except a multi-click's release at (nearly) the same spot: it
        # must not collapse the word/cell selection the press made.
        stationary = (lp = @last_press) &&
                     (pos.x - lp.x).abs <= CLICK_MAX_DIST &&
                     (pos.y - lp.y).abs <= CLICK_MAX_DIST
        if input.pointer_released? && stationary && @press_seq >= 2
          # keep the multi-click selection as is
        elsif (cell = hit_cell(pos, memory) || nearest_cell(pos))
          @focus = Pos.new(cell.id, caret_at(cell, pos), cell.flat)
        end
        @dragging = false if input.pointer_released?
      else
        @dragging = false if input.pointer_released?
      end
    end

    private def hotkeys(input : InputState, memory : Memory) : Nil
      return unless memory.focus.clipboard_shortcuts_free?
      if any_selection? && input.consume_key(KeyCode::Escape)
        clear
      elsif any_selection? && input.modifiers.command? &&
            input.consume_key(KeyCode::C)
        # Only claim the key when there is something to copy — an
        # unfocused TextEdit/TextArea handles its own Ctrl+C after this
        # and must not find it consumed (same rule as the old per-label
        # handling).
        text = selected_text
        SystemPorts::Clipboard.text = text unless text.empty?
      elsif input.modifiers.command? &&
            !(@prev.empty? && @cells.empty?) &&
            input.consume_key(KeyCode::A)
        # With no text cells on screen there is nothing to select —
        # leave the key to the text widgets (a readonly view's own
        # select-all).
        select_all unless @prev.empty? && @cells.empty?
      end
    end

    # --- selection queries (widgets) ---------------------------------------

    # This cell's slice of the global selection, as a char range in its
    # flat text — nil when nothing of it is selected.
    def range_for(id : Id) : {Int32, Int32}?
      a = @anchor
      f = @focus
      return nil unless a && f
      return nil if a.id == f.id && a.char == f.char
      data = cell_of(id)
      return nil unless data
      flat_size = data.flat.size
      if endpoint_key(a, true) <= endpoint_key(f, false)
        start_pos, end_pos = a, f
      else
        start_pos, end_pos = f, a
      end
      lo = 0
      hi = flat_size
      if a.id == f.id && id == a.id
        # Both endpoints in one cell (a drag inside a single label).
        lo = {a.char, f.char}.min.clamp(0, flat_size)
        hi = {a.char, f.char}.max.clamp(0, flat_size)
      elsif id == start_pos.id
        lo = start_pos.char.clamp(0, flat_size)
      elsif id == end_pos.id
        hi = end_pos.char.clamp(0, flat_size)
      else
        ck = center_key(data)
        return nil unless between_keys?(data, ck)
      end
      return nil if lo >= hi
      {lo, hi}
    end

    # The selection's text in document order — what Ctrl+C and the
    # context menu Copy put on the clipboard. Cells join with "\n" (the
    # label-per-line layout is the norm; a same-row join heuristic can
    # come later). Prefer the previous frame's registrations: at
    # Ctrl+C time (begin_frame) this frame's are empty, and a menu Copy
    # runs mid-frame against an incomplete list.
    def selected_text : String
      a = @anchor
      f = @focus
      return "" unless a && f
      if a.id == f.id
        return "" if a.char == f.char
        # Both endpoints in one cell: a single slice.
        if (cell = cell_of(a.id)) && (r = range_for(a.id))
          return slice_source(cell, r[0], r[1])
        end
        lo = {a.char, f.char}.min.clamp(0, a.flat.size)
        hi = {a.char, f.char}.max.clamp(0, a.flat.size)
        return lo < hi ? a.flat[lo, hi - lo] : ""
      end
      if endpoint_key(a, true) <= endpoint_key(f, false)
        start_pos, end_pos = a, f
      else
        start_pos, end_pos = f, a
      end
      parts = [] of Tuple({Float64, Float64, Int32}, String)
      # Endpoint slices: the live cell when its widget still renders,
      # the snapshot text when it does not.
      {a, f}.each do |p|
        if (cell = cell_of(p.id))
          if (r = range_for(p.id))
            parts << {center_key(cell), slice_source(cell, r[0], r[1])}
          end
        else
          text = p.flat
          from_start = p.id == start_pos.id
          lo = from_start ? p.char.clamp(0, text.size) : 0
          hi = from_start ? text.size : p.char.clamp(0, text.size)
          key = p == a ? {-1.0e12, -1.0e12, 0} : {1.0e12, 1.0e12, 0}
          parts << {key, text[lo, hi - lo]} if lo < hi
        end
      end
      @prev.each_value do |cell|
        next if cell.id == a.id || cell.id == f.id
        if (r = range_for(cell.id))
          parts << {center_key(cell), slice_source(cell, r[0], r[1])}
        end
      end
      parts.sort_by!(&.[0])
      parts.map(&.[1]).join("\n")
    end

    # Ctrl/Cmd+A: everything the document selected — from the first
    # cell's start to the last cell's end (geometric order).
    def select_all : Nil
      cells = @prev.empty? ? @cells : @prev
      return if cells.empty?
      first = cells.values.min_by { |c| center_key(c) }
      last = cells.values.max_by { |c| center_key(c) }
      @anchor = Pos.new(first.id, 0, first.flat)
      @focus = Pos.new(last.id, last.flat.size, last.flat)
    end

    # A cell's own "Select all" context-menu row.
    def select_cell(id : Id, flat : String) : Nil
      @anchor = Pos.new(id, 0, flat)
      @focus = Pos.new(id, flat.size, flat)
    end

    # --- geometry ----------------------------------------------------------

    private def cell_of(id : Id) : CellData?
      @cells[id]? || @prev[id]?
    end

    # The cell the pointer pressed on, occlusion-aware: geometric
    # containment first (cheap), then Memory#interaction_state — the
    # same hover verdict widgets see (layer z, modal, scroll clips).
    # Last registration wins among same-layer overlaps (paint order:
    # the topmost cell painted last).
    private def hit_cell(pos : Pos2, memory : Memory) : CellData?
      best = nil
      @prev.each_value do |cell|
        next unless cell.rect.contains?(pos)
        best = cell if memory.interaction_state(cell.id)
      end
      best
    end

    # Nearest cell by rect distance — the drag's between-cells fallback
    # (the browser picks the nearest text position too).
    private def nearest_cell(pos : Pos2) : CellData?
      best = nil
      best_d = Float64::INFINITY
      @prev.each_value do |cell|
        dx = {cell.rect.left - pos.x, 0.0, pos.x - cell.rect.right}.max
        dy = {cell.rect.top - pos.y, 0.0, pos.y - cell.rect.bottom}.max
        d = dx * dx + dy * dy
        if d < best_d
          best_d = d
          best = cell
        end
      end
      best
    end

    # Char offset of the pointer in a cell's flat text — Label's caret
    # geometry, verbatim (nearest boundary in the row under the y).
    def caret_at(cell : CellData, pos : Pos2) : Int32
      galley = cell.galley
      return 0 if galley.rows.empty?
      crect = cell.content_rect
      local_x = pos.x - crect.left
      local_y = pos.y - crect.top
      row_index = 0
      galley.rows.each_with_index do |row, i|
        row_index = i
        break if local_y < row.y + row.height
      end
      row = galley.rows[row_index]
      text = row.text
      local_x -= cell.align_dx(row)
      return cell.row_starts[row_index] + text.size if local_x >= row.width
      # Nearest boundary, half-glyph snapping (the browser caret rule):
      # a pointer INSIDE a glyph snaps to the nearer of its two edges,
      # so the first/last glyph of a row can be grabbed when selecting
      # toward it — snapping to the next glyph START drops it.
      prev = 0.0
      best = text.size
      (1..text.size).each do |i|
        x = galley.x_at(row_index, i, cell.fonts, cell.resolve)
        if x >= local_x
          best = (x - local_x) <= (local_x - prev) ? i : i - 1
          break
        end
        prev = x
      end
      cell.row_starts[row_index] + best
    end

    # Sort key of an endpoint: its caret's row and x position. A cell
    # with no resolvable geometry sorts before everything (anchor) or
    # after everything (focus) — a culled cell keeps the selection
    # spanning toward the visible end.
    private def endpoint_key(pos : Pos, missing_before : Bool) : {Float64, Float64, Int32}
      if (cell = cell_of(pos.id))
        galley = cell.galley
        return {cell.rect.top + galley.size.y / 2.0, cell.rect.left, cell.seq} if galley.rows.empty?
        crect = cell.content_rect
        char = pos.char.clamp(0, cell.flat.size)
        row_index = 0
        galley.rows.each_with_index do |row, i|
          row_index = i
          break if char <= cell.row_starts[i] + row.text.size
        end
        row = galley.rows[row_index]
        x = crect.left + cell.align_dx(row) +
            galley.x_at(row_index, char - cell.row_starts[row_index],
              cell.fonts, cell.resolve)
        y = crect.top + row.y + row.height / 2.0
        {y, x, cell.seq}
      elsif missing_before
        {-1.0e12, -1.0e12, 0}
      else
        {1.0e12, 1.0e12, 0}
      end
    end

    private def center_key(cell : CellData) : {Float64, Float64, Int32}
      c = cell.rect.center
      {c.y, c.x, cell.seq}
    end

    # Is a cell with center key `ck` between the endpoints? The
    # endpoint keys are recomputed against THIS cell's key — no global
    # ordering state needed while widgets paint mid-frame.
    private def between_keys?(cell : CellData,
                              ck : {Float64, Float64, Int32}) : Bool
      a = @anchor.not_nil!
      f = @focus.not_nil!
      ka = endpoint_key(a, true)
      kf = endpoint_key(f, false)
      kstart = ka <= kf ? ka : kf
      kend = ka <= kf ? kf : ka
      kstart <= ck && ck <= kend
    end

    # Flat-text range → copy text: plain labels map back onto the
    # ORIGINAL text ('\n' dropped by layout); the rest copy flat.
    private def slice_source(cell : CellData, min : Int32,
                             max : Int32) : String
      return cell.flat[min, max - min] unless cell.map_newlines?
      text = cell.source
      return text[min, max - min] unless text.includes?('\n')
      map = [] of Int32
      text.each_char_with_index do |ch, i|
        map << i unless ch == '\n'
      end
      map << text.size
      lo = map[min]? || text.size
      hi = map[max]? || text.size
      text[lo, hi - lo]
    end

    # Word around `pos` for double-click selection — Label's word_range
    # (ASCII letters and digits group together, char units).
    private def word_range(text : String, pos : Int32) : {Int32, Int32}
      return {0, text.size} if text.empty?
      pos = pos.clamp(0, text.size - 1)
      l = pos
      while l > 0 && same_word_class?(text[l - 1], text[pos])
        l -= 1
      end
      r = pos
      while r < text.size - 1 && same_word_class?(text[r], text[r + 1])
        r += 1
      end
      {l, r + 1}
    end

    private def same_word_class?(a : Char, b : Char) : Bool
      word_char?(a) && word_char?(b) || !word_char?(a) && !word_char?(b) &&
        a == b # punctuation splits per character
    end

    private def word_char?(ch : Char) : Bool
      ch.ascii_letter? || ch.ascii_number?
    end
  end
end
