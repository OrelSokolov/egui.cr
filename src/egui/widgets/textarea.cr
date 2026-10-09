# Port of egui_upstream/crates/egui/src/widgets/text_edit/ (stage 3:
# multiline) shaped like an HTML `<textarea>`: soft word-wrap, per-line
# selection and caret, its own kinetic-scrolled viewport (history.cr)
# and a scrollbar when the content outgrows the box.
#
# The cursor and selection anchor are CHARACTER indexes into the
# whole buffer (IdTypeMap cells under the widget id, like TextEdit —
# Crystal String#[]/.size count characters, not bytes); the galley
# maps them to rows via `Row#newline_before` — a wrap break consumes
# no character, a newline break consumes one. Keyboard is the full
# TextEdit set plus Enter (newline), line-wise Home/End, row-wise
# Up/Down and page-wise PageUp/PageDown (a viewport page, column
# kept); paste keeps line breaks (the single-line field flattens
# them).
#
# BIG buffers (over BIG_TEXT_BYTES) switch to a virtual, `less`-style
# mode: the text is indexed once (line-start character offsets) and
# only a window of rows around the viewport is ever laid out — one row
# per source line, no soft wrap (long lines clip at the right edge,
# like less). Wrapping a multi-megabyte file at open would freeze the
# frame for seconds; the window rebuilds on scroll for pocket change.

module Egui
  class TextArea
    include Widget

    ANCHOR_SALT = 0x5EED_u64
    SCROLL_SALT = 0x5C40_u64
    VEL_SALT    =  0x7E1_u64
    BAR_SALT    =  0xBA2_u64
    BAR_W       =        8.0
    # Above this size (bytes) the textarea goes virtual — see the file
    # header. 512 KiB still full-wraps in ~100 ms once; past it, the
    # open-time wrap and the per-edit re-wrap stop being pocket change.
    BIG_TEXT_BYTES = 1 << 19

    def initialize(@text : String, @hint : String? = nil, @rows : Int32 = 8,
                   @frame : Bool = true, @focus_id : String? = nil,
                   @cursor_style : Symbol = :line,
                   @cursor_blinks : Bool = true)
    end

    # Cross-frame state for the virtual big-text mode: TextArea widgets
    # are recreated every frame, so the line index and the last built
    # row window live here, keyed by widget id (bounded — the handful
    # of open documents). Entries are dropped wholesale when their text
    # object changes (edits produce a new String; identity, not an
    # O(n) compare, decides).
    class VirtualState
      property text : String
      property starts : Array(Int32)
      property galley : Galley? = nil
      property row_starts : Array(Int32) = [0]
      property k0 : Int32 = 0
      property k1 : Int32 = 0

      def initialize(@text : String, @starts : Array(Int32))
      end
    end

    @@virtual_cache = {} of Id => VirtualState
    VIRTUAL_CACHE_MAX = 16

    def self.virtual_state(id : Id, text : String) : VirtualState
      st = @@virtual_cache[id]?
      if st.nil? || !st.text.same?(text)
        st = VirtualState.new(text, line_char_starts(text))
        while @@virtual_cache.size >= VIRTUAL_CACHE_MAX
          @@virtual_cache.shift
        end
        @@virtual_cache[id] = st
      end
      st
    end

    # Character offset of every line start (size = line count + 1: the
    # last entry is the phantom line after a trailing newline). One
    # byte scan: UTF-8 lead bytes count a character, 0x0A closes a
    # line. O(bytesize), once per buffer identity.
    def self.line_char_starts(text : String) : Array(Int32)
      starts = [0]
      bytes = text.to_unsafe
      n = text.bytesize
      chars = 0
      i = 0
      while i < n
        b = bytes[i]
        if b == 0x0A
          chars += 1
          starts << chars
        elsif b & 0xC0 != 0x80
          chars += 1
        end
        i += 1
      end
      starts
    end

    # Line index containing a character offset (binary search; rows are
    # lines in virtual mode, so unlike the wrapped galley there is no
    # boundary ambiguity — a line start belongs to its own line).
    def self.line_of(starts : Array(Int32), char : Int32) : Int32
      lo = 0
      hi = starts.size - 1
      ans = 0
      while lo <= hi
        mid = (lo + hi) // 2
        if starts[mid] <= char
          ans = mid
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      ans
    end

    # Build (or reuse) the window of laid-out rows around the viewport.
    # The window spans one screen of margin rows on each side, so
    # caret moves, page steps and smooth scrolling resolve against
    # built rows; it rebuilds only when the viewport leaves it. Rows
    # carry GLOBAL y (line index * line_h) — painting, culling and the
    # scroll math all keep their absolute-offset meaning, and
    # row_starts stays a slice of the global line starts so caret and
    # selection indexes need no translation.
    def self.virtual_window(st : VirtualState, offset : Float64,
                            view_h : Float64, line_h : Float64,
                            fonts : Fonts, font_size : Float64)
      lines = st.starts.size
      vis = {(view_h / line_h).ceil.to_i, 1}.max
      lv0 = (offset / line_h).floor.to_i.clamp(0, {lines - 1, 0}.max)
      lv1 = ((offset + view_h) / line_h).ceil.to_i.clamp(0, lines)
      if (g = st.galley) && lv0 >= st.k0 + vis && lv1 <= st.k1 - vis
        return {g, st.row_starts}
      end
      k0 = {lv0 - vis, 0}.max
      k1 = {lv1 + vis, lines}.min
      k1 = {k1, {lv0 + 1, lines}.min}.max # degenerate: zero-height view
      text = st.text
      rows = [] of Galley::Row
      (k0...k1).each do |li|
        s = st.starts[li]
        e = li + 1 < st.starts.size ? st.starts[li + 1] - 1 : text.size
        line_text = text[s, e - s]
        w = fonts.measure(line_text, font_size).x
        rows << Galley::Row.new(
          [Galley::RowRun.new(line_text, 0.0, font_size, nil, false)],
          w, line_h, li.to_f64 * line_h, li > 0)
      end
      galley = Galley.new(rows)
      # Starts aligned to the window's rows, padded to rows+1 entries
      # (the extra entry is the start past the window / buffer end).
      rs = st.starts[k0...{k1 + 1, st.starts.size}.min].dup
      while rs.size < rows.size + 1
        rs << text.size
      end
      st.galley = galley
      st.row_starts = rs
      st.k0 = k0
      st.k1 = k1
      {galley, rs}
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts_for(style.font_family)
      memory = ui.ctx.memory
      input = ui.ctx.input
      id = @focus_id ? ui.named_id(@focus_id.not_nil!) : ui.next_widget_id

      anchor_id = id.child(ANCHOR_SALT)
      scroll_id = id.child(SCROLL_SALT)
      vel_id = scroll_id.child(3)
      memory.use_id(anchor_id)
      memory.use_id(vel_id)

      line_h = font_size * Fonts::LINE_H_FACTOR
      pad = style.spacing.button_padding
      # The border stroke is drawn INSIDE the rect (backend inset), so
      # layout reserves it on every side (same as TextEdit). A FRAMELESS
      # textarea (frame: false) fills its rect edge to edge — no box,
      # no inset (a full-bleed editor like Notepad's page).
      border = 2.0
      inset = @frame ? Vec2.new(pad.x + border, pad.y + border) : Vec2.zero

      width = ui.available_width
      height = @rows * line_h + inset.y * 2.0
      rect = ui.allocate_at_least(Vec2.new(width, height))
      response = ui.interact(rect, id,
        Sense::Click | Sense::Drag | Sense::Focusable)
      ui.ctx.set_cursor_icon(CursorIcon::Text) if response.hovered?

      # Word-wrapped layout of the real buffer (never the hint — the
      # caret/selection math runs on it). The scrollbar column is
      # always reserved, like browsers do. The wrap width and viewport
      # height follow the ALLOCATED rect, not the request — the
      # max-size rule can clamp it to the parent (e.g. a fill-the-panel
      # textarea with rows set high), and a viewport taller than the
      # real rect would zero the scroll range.
      wrap_w = {rect.width - inset.x * 2.0 - BAR_W, 10.0}.max
      # BIG buffers go virtual (see the class comment): the file is
      # never wrapped whole — a window of rows around the viewport is
      # laid out instead, after the offset is known. Small buffers
      # take the full word-wrap, cached in Fonts across frames.
      virtual = @text.bytesize > BIG_TEXT_BYTES
      vstate = virtual ? self.class.virtual_state(id, @text) : nil

      inner = Rect.from_min_size(rect.min + inset,
        Vec2.new(wrap_w, rect.height - inset.y * 2.0))
      view_h = inner.height
      # The scroll range comes from the content height: the wrapped
      # galley's own height, or lines × line height in virtual mode.
      content_h : Float64
      if vstate
        content_h = vstate.starts.size.to_f64 * line_h
      else
        galley = fonts.layout([TextRun.new(@text, font_size)],
          max_width: wrap_w)
        row_starts = galley.row_char_starts
        content_h = galley.size.y
      end
      max_offset = {content_h - view_h, 0.0}.max

      # --- scrolling: kinetic, the same scheme as ScrollArea ---------
      memory.register_scroll_area(scroll_id, rect, ui.layer)
      kin = KineticScroller.new(
        memory.data.get_vec2(scroll_id, Vec2.zero).y,
        memory.data.get_f64(vel_id, 0.0),
        memory.scroll_history(scroll_id))
      if memory.active_scroll_area? == scroll_id && !input.scroll.y.zero?
        kin.input(input.scroll.y * style.scroll_speed, input.time,
          max_offset)
      else
        kin.glide(input.dt, max_offset, ui.ctx)
      end
      offset = kin.offset
      # The virtual window is laid out around the (now known) offset;
      # the wrapped galley was laid out above. Both leave `galley`/
      # `row_starts` bound for everything below.
      if vstate
        galley, row_starts = self.class.virtual_window(vstate, offset,
          view_h, line_h, fonts, font_size)
      else
        galley = galley.not_nil!
        row_starts = row_starts.not_nil!
      end

      cursor = memory.data.get_int(id, virtual ? 0 : @text.size)
        .clamp(0, @text.size)
      cursor_prev = cursor
      anchor = memory.data.get_int(anchor_id, -1)
      new_text = @text
      changed = false

      # Press places the caret, double-click selects a word, dragging
      # extends the selection (anchor latched at the press).
      if response.pressed? || response.clicked?
        response.request_focus
        if (pos = input.pointer_pos)
          if response.double_clicked?
            cursor, anchor = word_range(@text,
              caret_at(galley, row_starts, fonts, inner, offset, pos))
          else
            cursor = caret_at(galley, row_starts, fonts, inner, offset, pos)
            anchor = cursor
          end
        end
      end
      if response.drag_started? && (pos = input.pointer_pos) && anchor == -1
        anchor = caret_at(galley, row_starts, fonts, inner, offset, pos)
      end
      if response.dragged? && (pos = input.pointer_pos)
        cursor = caret_at(galley, row_starts, fonts, inner, offset, pos)
      end

      # Virtual mode: the keyboard pass maps the caret through the
      # built row window — if a NAVIGATION key is pressed while the
      # caret sits outside the window (scrollbar jump, select-all, a
      # scroll away from the caret), recenter the window on it first
      # so Up/Down/PageUp/End resolve against the right rows. Gated on
      # nav keys on purpose: on every focused frame it would fight the
      # scrollbar and the wheel, snapping the viewport back to the
      # caret right after the user scrolled away.
      if vstate && response.has_focus? && nav_key?(input)
        li = self.class.line_of(vstate.starts, cursor)
        if li < vstate.k0 || li >= vstate.k1
          kin.takeover
          offset = (li.to_f64 * line_h - view_h / 2.0).clamp(0.0, max_offset)
          galley, row_starts = self.class.virtual_window(vstate, offset,
            view_h, line_h, fonts, font_size)
        end
      end

      if response.has_focus?
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_text, cursor, anchor, changed =
          handle_keyboard(ui.ctx, @text, cursor, anchor,
            galley, row_starts, fonts, view_h)
        ui.ctx.request_repaint if @cursor_blinks # caret blink
      end

      # The galley was laid out from the OLD buffer before the keyboard
      # pass — after an edit the new caret index maps onto stale rows
      # (past a row end it lands on the phantom row below: the caret
      # "jumped a line" for a frame). Re-lay the galley so the painted
      # text, caret, selection and viewport all reflect the NEW buffer
      # this frame. (Movement keys intentionally keep the old galley —
      # indexes there are clamped by design.)
      if changed
        if vstate
          # New buffer identity: rebuild the line index (one byte scan)
          # and the row window against it.
          vstate = self.class.virtual_state(id, new_text)
          content_h = vstate.starts.size.to_f64 * line_h
          max_offset = {content_h - view_h, 0.0}.max
          galley, row_starts = self.class.virtual_window(vstate, offset,
            view_h, line_h, fonts, font_size)
        else
          galley = fonts.layout([TextRun.new(new_text, font_size)],
            max_width: wrap_w)
          row_starts = galley.row_char_starts
          content_h = galley.size.y
          max_offset = {content_h - view_h, 0.0}.max
        end
      end

      # Keep the caret's row inside the viewport — but only when the
      # caret or the text actually changed this frame (upstream
      # `scroll_to_rect` on `response.changed() || selection_changed`).
      # Every frame would pin the viewport to the caret and make wheel
      # scrolling away from it impossible.
      if response.has_focus? && (changed || cursor != cursor_prev)
        if vstate
          top = self.class.line_of(vstate.starts, cursor).to_f64 * line_h
          bottom = top + line_h
        else
          row_index, col = caret_row_col(galley, row_starts, cursor)
          row = galley.rows[row_index]?
          top = row ? row.y : galley.size.y
          bottom = top + (row ? row.height : line_h)
        end
        if top < offset
          kin.takeover
          offset = top
        elsif bottom > offset + view_h
          kin.takeover
          offset = bottom - view_h
        end
      end
      offset = offset.clamp(0.0, max_offset)

      memory.data.set_int(id, cursor)
      memory.data.set_int(anchor_id, anchor)

      # --- painting (clipped to the box) -----------------------------
      # The box never changes with focus (HTML <textarea> semantics:
      # focus shows itself only through the blinking caret) — unlike
      # the single-line TextEdit, which paints the accent border
      # upstream-style. frame: false skips the box entirely.
      visuals = style.visuals
      if @frame
        ui.painter.rect(rect, 4.0, visuals.button_weak,
          visuals.button_stroke, 1.0)
      end

      outer_clip = ui.painter.clip
      ui.painter.clip = Rect.new(
        Pos2.new({outer_clip.min.x, inner.min.x}.max,
          {outer_clip.min.y, inner.min.y}.max),
        Pos2.new({outer_clip.max.x, inner.max.x}.min,
          {outer_clip.max.y, inner.max.y}.min))

      # Selection highlight, per visible row — painted UNDER the text
      # (like the single-line TextEdit and browsers: the fill must not
      # cover the glyphs it selects). Only rows intersecting the
      # viewport are painted — a selection spanning a huge buffer must
      # not walk (and measure) every row each frame.
      if anchor >= 0 && anchor != cursor && !new_text.empty?
        sel_min, sel_max = {cursor, anchor}.min, {cursor, anchor}.max
        galley.rows.each_with_index do |row, i|
          next if row.y + row.height < offset
          break if row.y > offset + view_h
          s = row_starts[i]
          a = {sel_min, s}.max
          b = {sel_max, s + row.text.size}.min
          next if b < a
          x0 = galley.x_at(i, a - s, fonts)
          x1 = galley.x_at(i, b - s, fonts)
          if x1 - x0 <= 0.0
            # Zero-width (an empty line): browsers still show a thin
            # sliver — paint one when the selection spans the whole
            # row INCLUDING its newline (row start of the next row).
            row_end = row_starts[i + 1]? || s
            next unless sel_min <= s && sel_max >= row_end
            x0 = 0.0
            x1 = 3.0
          end
          # Full row pitch (rows stack at exactly y += height): a
          # shrunk rect would leave unhighlighted stripes between
          # consecutive selected lines. The fill is a faded selection
          # color (same treatment as hover hints elsewhere) so the
          # highlight reads pale against the text.
          ui.painter.rect(
            Rect.from_min_size(
              Pos2.new(inner.min.x + x0, inner.min.y + row.y - offset),
              Vec2.new(x1 - x0, row.height)),
            0.0, visuals.fade_color(visuals.selection_fill, 0.4))
        end
      end

      color = if new_text.empty? && (hint = @hint)
                visuals.fade_color(visuals.text_color, 0.55)
              else
                visuals.text_color
              end
      ui.painter.paint_galley(inner.min - Vec2.new(0.0, offset), galley,
        fonts, color, style.font_family)
      # The hint is laid out as its own galley when the buffer is empty.
      if new_text.empty? && (hint = @hint)
        hint_galley = fonts.layout([TextRun.new(hint, font_size)],
          max_width: wrap_w)
        ui.painter.paint_galley(inner.min - Vec2.new(0.0, offset),
          hint_galley, fonts, color, style.font_family)
      end

      # Caret while focused: a 1px line by default, or a vim-style
      # BLOCK with `cursor_style: :block`; it BLINKS (1s period) unless
      # `cursor_blinks: false` holds it steady —
      # the block fills the cell of the character under the caret and
      # re-draws that character in the widget's background color
      # (inverse video); at end of line (or on an empty buffer) it
      # falls back to a space-width cell. In virtual mode a caret
      # outside the built window has no row to sit on — skip it (the
      # window recenters on the caret before the next frame).
      if response.has_focus? &&
         (@cursor_blinks ? (input.time % 1.0) < 0.6 : true)
        row_index, col = caret_row_col(galley, row_starts, cursor)
        row = galley.rows[row_index]?
        if row || !vstate
          caret_x = row ? galley.x_at(row_index, col, fonts) : 0.0
          top = inner.min.y + (row ? row.y : galley.size.y) - offset
          h = (row ? row.height : line_h) - 2.0
          if @cursor_style == :block
            w = row ? galley.x_at(row_index, col + 1, fonts) - caret_x : 0.0
            w = {fonts.measure(" ", font_size).x, font_size * 0.5}.max if w <= 0.0
            ui.painter.rect(
              Rect.from_min_size(Pos2.new(inner.min.x + caret_x, top + 1.0),
                Vec2.new(w, h)), 0.0, visuals.text_color)
            if row && (ch = row.text[col]?)
              glyph_bg = @frame ? visuals.button_weak : visuals.window_fill
              size = row.runs.map(&.size).max? || font_size
              ui.painter.text(
                Pos2.new(inner.min.x + caret_x, top + row.height / 2.0),
                ch.to_s, size, glyph_bg, family: style.font_family)
            end
          else
            ui.painter.line(Pos2.new(inner.min.x + caret_x, top + 1.0),
              Pos2.new(inner.min.x + caret_x, top + 1.0 + h),
              1.0, visuals.text_color)
          end
        end
      end

      ui.painter.clip = outer_clip

      # --- scrollbar (direct control, no inertia) --------------------
      kin_velocity = kin.velocity
      if content_h > view_h && view_h > 0.0
        track = Rect.from_min_size(
          Pos2.new(rect.right - BAR_W - border, rect.top + border),
          Vec2.new(BAR_W, rect.height - border * 2.0))
        bar_id = id.child(BAR_SALT)
        bar_resp = ui.interact(track, bar_id, Sense.click_and_drag)

        thumb_h = (view_h * view_h / content_h).clamp(12.0, view_h)
        scrollable = view_h - thumb_h
        thumb_y = ->(off : Float64) : Float64 do
          max_offset > 0.0 ? track.top + scrollable * off / max_offset : track.top
        end

        if (bar_resp.pressed? || bar_resp.dragged?) &&
           (pointer = input.pointer_pos)
          kin.takeover
          kin_velocity = 0.0
          grab = memory.data.get_f64(bar_id, Float64::NAN)
          if grab.nan?
            thumb_now = Rect.from_min_size(
              Pos2.new(track.left, thumb_y.call(offset)),
              Vec2.new(BAR_W, thumb_h))
            grab = thumb_now.contains?(pointer) ? pointer.y - thumb_now.top : thumb_h / 2.0
            memory.data.set_f64(bar_id, grab)
          end
          if scrollable > 0.0
            offset = ((pointer.y - grab - track.top) * max_offset / scrollable)
              .clamp(0.0, max_offset)
          end
        else
          memory.data.set_f64(bar_id, Float64::NAN)
        end

        ui.painter.rect(track, 4.0, visuals.button_weak)
        thumb = Rect.from_min_size(
          Pos2.new(track.left + 1.0, thumb_y.call(offset) + 1.0),
          Vec2.new(BAR_W - 2.0, {thumb_h - 2.0, 4.0}.max))
        # Same classic scheme as ScrollArea's overlay bar: face + stroke
        # border, button states for interaction (never the accent).
        thumb_color = visuals.button_hovered if bar_resp.hovered?
        thumb_color = visuals.button_active if bar_resp.pressed? || bar_resp.dragged?
        thumb_color ||= visuals.button_weak
        ui.painter.rect(thumb, 3.0, thumb_color, visuals.button_stroke, 1.0)
      end

      memory.data.set_vec2(scroll_id, Vec2.new(0.0, offset))
      memory.data.set_f64(vel_id, kin_velocity)

      response.widget_text = new_text
      response.mark_changed if changed
      response
    end

    # Character offset of each row start is Galley's job now (memoized
    # there — recomputing it here scanned and re-joined every row on
    # every frame, which is what pinned big buffers to O(n) per frame).

    # A caret-movement key that maps the caret through the galley
    # (rows the window must cover for the virtual-mode recenter).
    private def nav_key?(input : InputState) : Bool
      input.keys_pressed.any? do |k|
        KeyCode::Up == k || KeyCode::Down == k ||
          KeyCode::PageUp == k || KeyCode::PageDown == k ||
          KeyCode::Home == k || KeyCode::End == k
      end
    end

    # (row index, column in characters) of a caret character offset.
    # Row starts are strictly ascending and each row ends where the
    # next starts (minus its newline, if any) — a binary search finds
    # the row whose [start, end] contains the offset without scanning
    # the whole galley (this runs every frame for the caret blink).
    private def caret_row_col(galley : Galley, row_starts : Array(Int32),
                              char : Int32) : {Int32, Int32}
      starts = row_starts
      lo = 0
      hi = starts.size - 2 # last real row (the extra entry is phantom)
      while lo <= hi
        mid = (lo + hi) // 2
        s = starts[mid]
        row_end = s + galley.rows[mid].text.size
        if char < s
          hi = mid - 1
        elsif char > row_end
          lo = mid + 1
        else
          # A caret exactly on a wrap boundary belongs to the END of
          # the earlier row (what the linear scan this replaced
          # returned first) — its x is the row's full width, not 0.
          if char == s && mid > 0 && !galley.rows[mid].newline_before? &&
             starts[mid - 1] + galley.rows[mid - 1].text.size == char
            prev = mid - 1
            return {prev, galley.rows[prev].text.size}
          end
          return {mid, char - s}
        end
      end
      {galley.rows.size, 0} # phantom row past the end (empty buffer)
    end

    # Caret character offset at a pointer position (screen coords).
    private def caret_at(galley : Galley, row_starts : Array(Int32),
                         fonts : Fonts, inner : Rect, offset : Float64,
                         pos : Pos2) : Int32
      y = pos.y - inner.min.y + offset
      x = pos.x - inner.min.x
      row_index = nil
      galley.rows.each_with_index do |r, i|
        if y < r.y + r.height
          row_index = i
          break
        end
      end
      return row_starts[galley.rows.size]? || 0 unless row_index
      char_at(galley, row_starts, row_index.not_nil!, x, fonts)
    end

    # Row index whose vertical band contains a galley y (for page-wise
    # caret movement); y past the bottom clamps to the last row.
    private def row_at_y(galley : Galley, y : Float64) : Int32
      galley.rows.each_with_index do |r, i|
        return i if y < r.y + r.height
      end
      {galley.rows.size - 1, 0}.max
    end

    # Nearest caret character offset for an x position on a row.
    private def char_at(galley : Galley, row_starts : Array(Int32),
                        row_index : Int32, x : Float64,
                        fonts : Fonts) : Int32
      row = galley.rows[row_index]
      start = row_starts[row_index]
      text = row.text
      return start + text.size if x >= row.width
      best = 0
      text.size.times do |i|
        best = i
        break if galley.x_at(row_index, i, fonts) >= x
      end
      start + best
    end

    # Word around `pos` for double-click selection (character indexes).
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
        a == b
    end

    private def word_char?(ch : Char) : Bool
      ch.ascii_letter? || ch.ascii_number?
    end

    # Character stepping (Crystal String#[]/.size count characters,
    # so one index unit is one character — no UTF-8 byte walking).
    private def step_back(text : String, i : Int32) : Int32
      (i - 1).clamp(0, text.size)
    end

    private def step_fwd(text : String, i : Int32) : Int32
      (i + 1).clamp(0, text.size)
    end

    # Returns {text, cursor, anchor, changed}.
    private def handle_keyboard(ctx : Context, text : String, cursor : Int32,
                                anchor : Int32, galley : Galley,
                                row_starts : Array(Int32), fonts : Fonts,
                                view_h : Float64)
      input = ctx.input
      new_text = text
      new_cursor = cursor
      new_anchor = anchor
      changed = false
      has_sel = anchor >= 0 && anchor != cursor
      sel_min = {cursor, anchor}.min
      sel_max = {cursor, anchor}.max

      if input.consume_key(KeyCode::Escape)
        ctx.memory.focus.clear
        return {text, cursor, anchor, false}
      end

      # Clipboard through the system port; paste keeps line breaks.
      # Ctrl+Home / Ctrl+End live here too (document-wise jumps — the
      # ctrl block returns early below, before the plain movement keys).
      if input.modifiers.ctrl
        if input.consume_key(KeyCode::Home)
          # Caret (or, with Shift kept, the selection edge) to the very
          # top of the buffer; follow-caret turns it into the instant
          # jump to the start a big-buffer editor needs.
          new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
          new_cursor = 0
          new_anchor = new_cursor unless input.modifiers.shift
        elsif input.consume_key(KeyCode::End)
          new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
          new_cursor = text.size
          new_anchor = new_cursor unless input.modifiers.shift
        elsif input.consume_key(KeyCode::C)
          if has_sel
            Egui::SystemPorts::Clipboard.text = text[sel_min...sel_max]
          end
        elsif input.consume_key(KeyCode::X)
          if has_sel
            Egui::SystemPorts::Clipboard.text = text[sel_min...sel_max]
            new_text = text[0...sel_min] + text[sel_max..]
            new_cursor = new_anchor = sel_min
            changed = true
          end
        elsif input.consume_key(KeyCode::V)
          if (paste = Egui::SystemPorts::Clipboard.text)
            paste = paste.gsub(/\r\n|\r/, "\n")
            insert_at = has_sel ? sel_min : cursor
            tail = has_sel ? text[sel_max..] : text[cursor..]
            new_text = text[0...insert_at] + paste + tail
            new_cursor = new_anchor = insert_at + paste.size
            changed = true
          end
        elsif input.consume_key(KeyCode::A)
          new_anchor = 0
          new_cursor = text.size
        end
        return {new_text, new_cursor, new_anchor, changed}
      end

      # Selection-aware edits (UTF-8-char stepping).
      if input.consume_key(KeyCode::Backspace)
        if has_sel
          new_text = text[0...sel_min] + text[sel_max..]
          new_cursor = new_anchor = sel_min
        elsif cursor > 0
          from = step_back(text, cursor)
          new_text = text[0...from] + text[cursor..]
          new_cursor = new_anchor = from
        end
        changed = new_text != text
      elsif input.consume_key(KeyCode::Delete)
        if has_sel
          new_text = text[0...sel_min] + text[sel_max..]
          new_cursor = new_anchor = sel_min
        elsif cursor < text.size
          to = step_fwd(text, cursor)
          new_text = text[0...cursor] + text[to..]
          new_anchor = cursor
        end
        changed = new_text != text
      elsif input.consume_key(KeyCode::Enter)
        insert_at = has_sel ? sel_min : cursor
        tail = has_sel ? text[sel_max..] : text[cursor..]
        new_text = text[0...insert_at] + "\n" + tail
        new_cursor = new_anchor = insert_at + 1
        changed = true
      elsif !input.text.empty? && !input.shortcut_modifiers_down?
        insert = input.text.gsub(/\r\n|\r/, "\n")
        insert_at = has_sel ? sel_min : cursor
        tail = has_sel ? text[sel_max..] : text[cursor..]
        new_text = text[0...insert_at] + insert + tail
        new_cursor = new_anchor = insert_at + insert.size
        changed = true
      end

      # Cursor movement after edits so the caret lands correctly; the
      # galley still reflects the OLD text (rows were laid out before
      # the keyboard pass) — indexes are clamped to stay in range.
      clamp = ->(b : Int32) { b.clamp(0, text.size) }
      if input.consume_key(KeyCode::Left)
        if input.modifiers.shift
          new_anchor = new_cursor if new_anchor == -1
          new_cursor = clamp.call(step_back(text, new_cursor))
        elsif new_anchor >= 0 && new_anchor != new_cursor
          new_cursor = new_anchor = {new_cursor, new_anchor}.min
        else
          new_cursor = clamp.call(step_back(text, new_cursor))
          new_anchor = new_cursor
        end
      elsif input.consume_key(KeyCode::Right)
        if input.modifiers.shift
          new_anchor = new_cursor if new_anchor == -1
          new_cursor = clamp.call(step_fwd(text, new_cursor))
        elsif new_anchor >= 0 && new_anchor != new_cursor
          new_cursor = new_anchor = {new_cursor, new_anchor}.max
        else
          new_cursor = clamp.call(step_fwd(text, new_cursor))
          new_anchor = new_cursor
        end
      elsif input.key_pressed?(KeyCode::Up) && input.consume_key(KeyCode::Up)
        row_index, col = caret_row_col(galley, row_starts, new_cursor)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        if row_index <= 0
          new_cursor = row_starts[0]? || 0
        else
          x = galley.x_at(row_index, col, fonts)
          new_cursor = char_at(galley, row_starts, row_index - 1, x, fonts)
        end
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.key_pressed?(KeyCode::Down) && input.consume_key(KeyCode::Down)
        row_index, col = caret_row_col(galley, row_starts, new_cursor)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        if row_index >= galley.rows.size - 1
          new_cursor = text.size
        else
          x = galley.x_at(row_index, col, fonts)
          new_cursor = char_at(galley, row_starts, row_index + 1, x, fonts)
        end
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(KeyCode::PageUp)
        row_index, col = caret_row_col(galley, row_starts, new_cursor)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        if row_index <= 0
          new_cursor = row_starts[0]? || 0
        else
          # A page is the viewport minus one row of context (browsers
          # keep the current line visible); the caret keeps its column,
          # exactly like repeated Up.
          row = galley.rows[row_index]
          page = {view_h - row.height, row.height}.max
          target = {row_at_y(galley, row.y - page), row_index - 1}.min
          x = galley.x_at(row_index, col, fonts)
          new_cursor = char_at(galley, row_starts, target, x, fonts)
        end
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(KeyCode::PageDown)
        row_index, col = caret_row_col(galley, row_starts, new_cursor)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        if row_index >= galley.rows.size - 1
          new_cursor = text.size
        else
          row = galley.rows[row_index]
          page = {view_h - row.height, row.height}.max
          target = {row_at_y(galley, row.y + page), row_index + 1}.max
          target = {target, galley.rows.size - 1}.min
          x = galley.x_at(row_index, col, fonts)
          new_cursor = char_at(galley, row_starts, target, x, fonts)
        end
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(KeyCode::Home)
        row_index, _col = caret_row_col(galley, row_starts, new_cursor)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        new_cursor = row_starts[row_index]? || 0
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(KeyCode::End)
        row_index, _col = caret_row_col(galley, row_starts, new_cursor)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        row = galley.rows[row_index]?
        new_cursor = row ? row_starts[row_index] + row.text.size : text.size
        new_anchor = new_cursor unless input.modifiers.shift
      end

      {new_text, new_cursor, new_anchor, changed}
    end
  end
end
