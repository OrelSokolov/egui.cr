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
# TextEdit set plus Enter (newline), line-wise Home/End and row-wise
# Up/Down; paste keeps line breaks (the single-line field flattens
# them).

module Egui
  class TextArea
    include Widget

    ANCHOR_SALT = 0x5EED_u64
    SCROLL_SALT = 0x5C40_u64
    VEL_SALT    = 0x7E1_u64
    BAR_SALT    = 0xBA2_u64
    BAR_W       = 8.0

    def initialize(@text : String, @hint : String? = nil, @rows : Int32 = 8)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts
      memory = ui.ctx.memory
      input = ui.ctx.input
      id = ui.next_widget_id

      anchor_id = id.child(ANCHOR_SALT)
      scroll_id = id.child(SCROLL_SALT)
      vel_id = scroll_id.child(3)
      memory.use_id(anchor_id)
      memory.use_id(vel_id)

      line_h = font_size * Fonts::LINE_H_FACTOR
      pad = style.spacing.button_padding
      # The border stroke is drawn INSIDE the rect (backend inset), so
      # layout reserves it on every side (same as TextEdit).
      border = 2.0
      inset = Vec2.new(pad.x + border, pad.y + border)

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
      galley = fonts.layout([TextRun.new(@text, font_size)],
        max_width: wrap_w)
      row_starts = row_char_starts(galley)

      inner = Rect.from_min_size(rect.min + inset,
        Vec2.new(wrap_w, rect.height - inset.y * 2.0))
      view_h = inner.height
      max_offset = {galley.size.y - view_h, 0.0}.max

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

      cursor = memory.data.get_int(id, @text.size).clamp(0, @text.size)
      cursor_prev = cursor
      anchor = memory.data.get_int(anchor_id, -1)
      new_text = @text
      changed = false

      caret = ->(pos : Pos2) do
        caret_at(galley, row_starts, fonts, inner, offset, pos)
      end

      # Press places the caret, double-click selects a word, dragging
      # extends the selection (anchor latched at the press).
      if response.pressed? || response.clicked?
        response.request_focus
        if (pos = input.pointer_pos)
          if response.double_clicked?
            cursor, anchor = word_range(@text, caret.call(pos))
          else
            cursor = caret.call(pos)
            anchor = cursor
          end
        end
      end
      if response.drag_started? && (pos = input.pointer_pos) && anchor == -1
        anchor = caret.call(pos)
      end
      if response.dragged? && (pos = input.pointer_pos)
        cursor = caret.call(pos)
      end

      if response.has_focus?
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_text, cursor, anchor, changed =
          handle_keyboard(ui.ctx, @text, cursor, anchor,
            galley, row_starts, fonts)
        ui.ctx.request_repaint # caret blink
      end

      # The galley was laid out from the OLD buffer before the keyboard
      # pass — after an edit the new caret index maps onto stale rows
      # (past a row end it lands on the phantom row below: the caret
      # "jumped a line" for a frame). Re-lay the galley so the painted
      # text, caret, selection and viewport all reflect the NEW buffer
      # this frame. (Movement keys intentionally keep the old galley —
      # indexes there are clamped by design.)
      if changed
        galley = fonts.layout([TextRun.new(new_text, font_size)],
          max_width: wrap_w)
        row_starts = row_char_starts(galley)
        max_offset = {galley.size.y - view_h, 0.0}.max
      end

      # Keep the caret's row inside the viewport — but only when the
      # caret or the text actually changed this frame (upstream
      # `scroll_to_rect` on `response.changed() || selection_changed`).
      # Every frame would pin the viewport to the caret and make wheel
      # scrolling away from it impossible.
      if response.has_focus? && (changed || cursor != cursor_prev)
        row_index, col = caret_row_col(galley, row_starts, cursor)
        row = galley.rows[row_index]?
        top = row ? row.y : galley.size.y
        bottom = top + (row ? row.height : line_h)
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
      # upstream-style.
      visuals = style.visuals
      ui.painter.rect(rect, 4.0, visuals.button_weak,
        visuals.button_stroke, 1.0)

      outer_clip = ui.painter.clip
      ui.painter.clip = Rect.new(
        Pos2.new({outer_clip.min.x, inner.min.x}.max,
          {outer_clip.min.y, inner.min.y}.max),
        Pos2.new({outer_clip.max.x, inner.max.x}.min,
          {outer_clip.max.y, inner.max.y}.min))

      # Selection highlight, per visible row — painted UNDER the text
      # (like the single-line TextEdit and browsers: the fill must not
      # cover the glyphs it selects).
      if anchor >= 0 && anchor != cursor && !new_text.empty?
        sel_min, sel_max = {cursor, anchor}.min, {cursor, anchor}.max
        galley.rows.each_with_index do |row, i|
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
          ui.painter.rect(
            Rect.from_min_size(
              Pos2.new(inner.min.x + x0, inner.min.y + row.y - offset),
              Vec2.new(x1 - x0, row.height - 2.0)),
            2.0, visuals.selection_fill)
        end
      end

      color = if new_text.empty? && (hint = @hint)
                visuals.fade_color(visuals.text_color, 0.55)
              else
                visuals.text_color
              end
      ui.painter.paint_galley(inner.min - Vec2.new(0.0, offset), galley,
        fonts, color)
      # The hint is laid out as its own galley when the buffer is empty.
      if new_text.empty? && (hint = @hint)
        hint_galley = fonts.layout([TextRun.new(hint, font_size)],
          max_width: wrap_w)
        ui.painter.paint_galley(inner.min - Vec2.new(0.0, offset),
          hint_galley, fonts, color)
      end

      # Blinking caret (1s period) while focused.
      if response.has_focus? && (input.time % 1.0) < 0.6
        row_index, col = caret_row_col(galley, row_starts, cursor)
        row = galley.rows[row_index]?
        caret_x = inner.min.x + (row ? galley.x_at(row_index, col, fonts) : 0.0)
        top = inner.min.y + (row ? row.y : galley.size.y) - offset
        bottom = top + (row ? row.height : line_h)
        ui.painter.line(Pos2.new(caret_x, top + 1.0),
          Pos2.new(caret_x, bottom - 1.0), 1.0, visuals.text_color)
      end

      ui.painter.clip = outer_clip

      # --- scrollbar (direct control, no inertia) --------------------
      kin_velocity = kin.velocity
      if galley.size.y > view_h && view_h > 0.0
        track = Rect.from_min_size(
          Pos2.new(rect.right - BAR_W - border, rect.top + border),
          Vec2.new(BAR_W, rect.height - border * 2.0))
        bar_id = id.child(BAR_SALT)
        bar_resp = ui.interact(track, bar_id, Sense.click_and_drag)

        thumb_h = (view_h * view_h / galley.size.y).clamp(12.0, view_h)
        scrollable = view_h - thumb_h
        thumb_y = ->(off : Float64) : Float64 do
          max_offset > 0.0 ? track.top + scrollable * off / max_offset
                            : track.top
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
            grab = thumb_now.contains?(pointer) ? pointer.y - thumb_now.top
                                                : thumb_h / 2.0
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
        thumb_color = visuals.button_hovered
        if bar_resp.pressed? || bar_resp.dragged? || bar_resp.hovered?
          thumb_color = visuals.selection_fill
        end
        ui.painter.rect(thumb, 3.0, thumb_color)
      end

      memory.data.set_vec2(scroll_id, Vec2.new(0.0, offset))
      memory.data.set_f64(vel_id, kin_velocity)

      response.widget_text = new_text
      response.mark_changed if changed
      response
    end

    # Character offset of each row start (size rows+1: the extra entry is
    # the phantom row after a trailing newline). A wrap break consumes
    # no character; a newline break consumes one.
    private def row_char_starts(galley : Galley) : Array(Int32)
      starts = [0]
      galley.rows.each_with_index do |row, i|
        consumed = row.text.size
        consumed += 1 if galley.rows[i + 1]?.try(&.newline_before?) || false
        starts << starts[i] + consumed
      end
      starts
    end

    # (row index, column in characters) of a caret character offset.
    private def caret_row_col(galley : Galley, row_starts : Array(Int32),
                              char : Int32) : {Int32, Int32}
      galley.rows.each_with_index do |row, i|
        s = row_starts[i]
        if char >= s && char <= s + row.text.size
          return {i, char - s}
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
                                row_starts : Array(Int32), fonts : Fonts)
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
      if input.modifiers.ctrl
        if input.consume_key(KeyCode::C)
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
