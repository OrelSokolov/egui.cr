# Port of egui_upstream/crates/egui/src/widgets/text_edit/ (stages 1+3:
# single-line and multiline; selection/clipboard/IME follow in phase 7).
#
# Cursor position is system state (Int32 char index under the widget
# id, survives IdTypeMap pruning like every widget cell). While
# focused: text inserts at the cursor, Backspace/Delete edit around
# it, Enter (multiline) splits the line, Left/Right/Home/End move
# within the row, Up/Down (multiline) move between rows (arrows locked
# away from focus navigation), Escape drops focus. Clicking places the
# cursor via Galley#x_at. The new buffer flows out through
# Response#widget_text.
#
# Multiline wraps each logical line to the widget width. Lines are
# laid out as one galley each (not one galley for the whole buffer):
# `Fonts#layout` drops only '\n' chars, and a line contains none — so
# a line's galley rows concatenated are exactly the line's text and
# the char↔row mapping stays exact. The view scrolls just enough to
# keep the caret row visible (offset in IdTypeMap, like ScrollArea).

module Egui
  class TextEdit
    include Widget

    def initialize(@text : String, @hint : String? = nil,
                   @multiline : Bool = false, @rows : Int32 = 4,
                   @desired_width : Float64? = nil)
    end

    def ui(ui : Ui) : Response
      if @multiline
        multiline_ui(ui)
      else
        singleline_ui(ui)
      end
    end

    # --- single-line (stage 1) ------------------------------------------

    private def singleline_ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts
      id = ui.next_widget_id

      shown = @text.empty? && (hint = @hint) ? hint : @text
      runs = [TextRun.new(shown, font_size)]
      galley = fonts.layout(runs)

      pad = style.spacing.button_padding
      size = Vec2.new(
        {galley.size.x, style.spacing.interact_size.x}.max + pad.x * 2.0,
        {galley.size.y, style.spacing.interact_size.y}.max + pad.y * 2.0)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)
      # Upstream: text caret cursor over the edit field.
      ui.ctx.set_cursor_icon(CursorIcon::Text) if response.hovered?

      cursor = ui.ctx.memory.data.get_int(id, @text.size).clamp(0, @text.size)
      new_text = @text
      changed = false

      # Click-to-focus + click-to-place the cursor.
      if response.clicked?
        response.request_focus
        if (pos = ui.ctx.input.pointer_pos)
          cursor = cursor_at(fonts, galley, rect, pad, pos.x)
        end
      end

      if response.has_focus?
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_text, cursor, changed = handle_keyboard(ui.ctx, @text, cursor)
        ui.ctx.request_repaint # caret blink
      end
      ui.ctx.memory.data.set_int(id, cursor)

      visuals = style.visuals
      bg = response.has_focus? ? visuals.button_active : visuals.button_weak
      ui.painter.rect(rect, 4.0, bg, visuals.border_color, 1.0)

      inner = rect.min + pad
      color = if @text.empty? && @hint
                visuals.fade_color(visuals.text_color, 0.55)
              else
                visuals.text_color
              end
      ui.painter.paint_galley(inner, galley, fonts, color)

      # Blinking caret (1s period) while focused.
      if response.has_focus? && (ui.ctx.input.time % 1.0) < 0.6
        caret_x = inner.x + galley.x_at(0, cursor, fonts)
        top = inner.y + 1.0
        bottom = inner.y + galley.size.y - 1.0
        ui.painter.line(Pos2.new(caret_x, top), Pos2.new(caret_x, bottom),
          1.0, visuals.text_color)
      end

      response.widget_text = new_text
      response.mark_changed if changed
      response.paint_focus_ring(5.0)
      response
    end

    private def cursor_at(fonts : Fonts, galley : Galley, rect : Rect,
                          pad : Vec2, pointer_x : Float64) : Int32
      row = galley.rows[0]?
      text = row.try(&.text) || ""
      return text.size if pointer_x >= rect.left + pad.x + galley.size.x

      best = 0
      text.size.times do |i|
        x = galley.x_at(0, i, fonts)
        best = i
        break if rect.left + pad.x + x >= pointer_x
      end
      best
    end

    # Returns {text, cursor, changed}.
    private def handle_keyboard(ctx : Context, text : String, cursor : Int32)
      input = ctx.input
      new_text = text
      new_cursor = cursor
      changed = false

      if input.consume_key(KeyCode::Escape)
        ctx.memory.focus.clear
        return {text, cursor, false}
      end
      if input.consume_key(KeyCode::Backspace) && cursor > 0
        new_text = text[0...(cursor - 1)] + text[cursor..]
        new_cursor = cursor - 1
        changed = true
      elsif input.consume_key(KeyCode::Delete) && cursor < text.size
        new_text = text[0...cursor] + text[(cursor + 1)..]
        changed = true
      elsif !input.text.empty?
        new_text = text[0...cursor] + input.text + text[cursor..]
        new_cursor = cursor + input.text.size
        changed = true
      end

      # Cursor movement (after edits so the caret lands correctly).
      if input.consume_key(KeyCode::Left)
        new_cursor = (new_cursor - 1).clamp(0, new_text.size)
      elsif input.consume_key(KeyCode::Right)
        new_cursor = (new_cursor + 1).clamp(0, new_text.size)
      elsif input.consume_key(KeyCode::Home) ||
           input.consume_key(KeyCode::Up)
        new_cursor = 0
      elsif input.consume_key(KeyCode::End) ||
           input.consume_key(KeyCode::Down)
        new_cursor = new_text.size
      end

      {new_text, new_cursor, changed}
    end

    # --- multiline (stage 3) --------------------------------------------

    # One logical line: its galley (wrapped to the widget width) plus
    # the char index the line starts at in the buffer.
    private class LineLayout
      getter galley : Galley
      getter start : Int32
      getter height : Float64

      def initialize(@galley : Galley, @start : Int32, min_height : Float64)
        @height = {@galley.size.y, min_height}.max
      end
    end

    private def multiline_ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts
      id = ui.next_widget_id

      width = {(@desired_width || ui.available_width), 40.0}.max
      pad = style.spacing.button_padding
      row_h = font_size * Fonts::LINE_H_FACTOR
      height = {@rows, 1}.max * row_h + pad.y * 2.0
      rect = ui.allocate_at_least(Vec2.new(width, height))
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)
      ui.ctx.set_cursor_icon(CursorIcon::Text) if response.hovered?

      cursor = ui.ctx.memory.data.get_int(id, @text.size).clamp(0, @text.size)
      new_text = @text
      changed = false

      max_width = width - pad.x * 2.0
      lines = layout_lines(fonts, font_size, shown_text, max_width, row_h)

      # Click-to-focus + click-to-place the cursor (row by pointer y,
      # column by x — the inverse of the caret geometry).
      if response.clicked?
        response.request_focus
        if (pos = ui.ctx.input.pointer_pos)
          cursor = cursor_from_pos(lines, rect, pad, pos, fonts)
            .clamp(0, @text.size)
        end
      end

      if response.has_focus?
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_text, cursor, changed = handle_keyboard_multiline(
          ui.ctx, @text, cursor)
        # Re-layout so the caret and view track the edited text this
        # same frame (upstream lays out the new state before painting).
        if changed
          lines = layout_lines(fonts, font_size,
            new_text.empty? ? shown_text : new_text, max_width, row_h)
        end
        ui.ctx.request_repaint # caret blink
      end
      ui.ctx.memory.data.set_int(id, cursor)

      visuals = style.visuals
      bg = response.has_focus? ? visuals.button_active : visuals.button_weak
      ui.painter.rect(rect, 4.0, bg, visuals.border_color, 1.0)

      # Scroll the view just enough to keep the caret row visible.
      view_h = height - pad.y * 2.0
      text_height = lines.sum(&.height)
      offset = ui.ctx.memory.data.get_f64(id.child(0), 0.0)
      if response.has_focus?
        _, caret_top, caret_bottom = caret_geometry(lines, cursor, fonts, row_h)
        offset = caret_top if caret_top < offset
        offset = caret_bottom - view_h if caret_bottom > offset + view_h
      end
      offset = offset.clamp(0.0, {text_height - view_h, 0.0}.max)
      ui.ctx.memory.data.set_f64(id.child(0), offset)

      # Clip painting to the field (intersected with the ambient clip,
      # the ScrollArea trick) so wrapped content scrolls behind the
      # border instead of painting over the neighbors.
      outer_clip = ui.painter.clip
      ui.painter.clip = Rect.new(
        Pos2.new({outer_clip.min.x, rect.min.x}.max,
          {outer_clip.min.y, rect.min.y}.max),
        Pos2.new({outer_clip.max.x, rect.max.x}.min,
          {outer_clip.max.y, rect.max.y}.min))

      inner = rect.min + pad
      color = if new_text.empty? && @hint
                visuals.fade_color(visuals.text_color, 0.55)
              else
                visuals.text_color
              end
      y = 0.0
      lines.each do |line|
        ui.painter.paint_galley(
          Pos2.new(inner.x, inner.y - offset + y), line.galley, fonts, color)
        y += line.height
      end

      # Blinking caret (1s period) while focused, on its visual row.
      if response.has_focus? && (ui.ctx.input.time % 1.0) < 0.6
        caret_x, caret_top, caret_bottom = caret_geometry(lines, cursor,
          fonts, row_h)
        ui.painter.line(
          Pos2.new(inner.x + caret_x, inner.y - offset + caret_top + 1.0),
          Pos2.new(inner.x + caret_x, inner.y - offset + caret_bottom - 1.0),
          1.0, visuals.text_color)
      end

      ui.painter.clip = outer_clip

      response.widget_text = new_text
      response.mark_changed if changed
      response.paint_focus_ring(5.0)
      response
    end

    private def shown_text : String
      @text.empty? && (hint = @hint) ? hint : @text
    end

    # Split `text` into logical lines and wrap each to `max_width`.
    # `String#split` drops trailing empty fields, so a buffer ending
    # in '\n' gets one appended back (the caret sits on that empty
    # line, at buffer end).
    private def layout_lines(fonts : Fonts, font_size : Float64,
                             text : String, max_width : Float64,
                             row_h : Float64) : Array(LineLayout)
      parts = text.split('\n')
      parts << "" if text.ends_with?('\n')

      start = 0
      parts.map_with_index do |part, i|
        galley = fonts.layout([TextRun.new(part, font_size)],
          {max_width, 1.0}.max)
        line = LineLayout.new(galley, start, row_h)
        start += part.size + 1
        line
      end
    end

    # {line_index, col} of a buffer char index — the last line whose
    # start is <= index (a cursor exactly on a line start belongs to
    # that line).
    private def line_col(lines : Array(LineLayout), index : Int32) : {Int32, Int32}
      li = 0
      lines.each_with_index do |line, i|
        break if line.start > index
        li = i
      end
      {li, index - lines[li].start}
    end

    # Visual-row geometry of the caret: {x, top, bottom} relative to
    # the text origin. A column past the last wrapped row's end
    # (cursor after the line's final char) rides the last row; a
    # column on a row boundary belongs to the earlier row's end.
    private def caret_geometry(lines : Array(LineLayout), cursor : Int32,
                               fonts : Fonts,
                               row_h : Float64) : {Float64, Float64, Float64}
      li, col = line_col(lines, cursor)
      y_before = lines[0...li].sum(&.height)
      line = lines[li]
      rows = line.galley.rows
      return {0.0, y_before, y_before + row_h} if rows.empty?

      char_off = 0
      rows.each_with_index do |row, ri|
        if col <= char_off + row.text.size
          x = line.galley.x_at(ri, col - char_off, fonts)
          return {x, y_before + row.y, y_before + row.y + row.height}
        end
        char_off += row.text.size
      end

      last = rows.last
      x = line.galley.x_at(rows.size - 1, last.text.size, fonts)
      {x, y_before + last.y, y_before + last.y + last.height}
    end

    # Inverse of #caret_geometry: pointer position → buffer char
    # index. Row by y, then the nearest char boundary by x (past the
    # row's right edge → after its last char).
    private def cursor_from_pos(lines : Array(LineLayout), rect : Rect,
                                pad : Vec2, pos : Pos2,
                                fonts : Fonts) : Int32
      local_y = pos.y - rect.top - pad.y
      y = 0.0
      lines.each do |line|
        rows = line.galley.rows
        char_off = 0
        rows.each_with_index do |row, ri|
          if local_y < y + row.y + row.height
            best = 0
            row.text.size.times do |i|
              best = i
              break if rect.left + pad.x + line.galley.x_at(ri, i, fonts) >= pos.x
            end
            if pos.x >= rect.left + pad.x +
                         line.galley.x_at(ri, row.text.size, fonts)
              best = row.text.size
            end
            return line.start + char_off + best
          end
          char_off += row.text.size
        end
        # No rows on this click (empty-galley line, height from row_h).
        return line.start if local_y < y + line.height
        y += line.height
      end
      lines.last.start
    end

    # Returns {text, cursor, changed}.
    private def handle_keyboard_multiline(ctx : Context, text : String,
                                          cursor : Int32)
      input = ctx.input
      new_text = text
      new_cursor = cursor
      changed = false

      if input.consume_key(KeyCode::Escape)
        ctx.memory.focus.clear
        return {text, cursor, false}
      end
      if input.consume_key(KeyCode::Backspace) && new_cursor > 0
        new_text = text[0...(new_cursor - 1)] + text[new_cursor..]
        new_cursor -= 1
        changed = true
      elsif input.consume_key(KeyCode::Delete) && new_cursor < text.size
        new_text = text[0...new_cursor] + text[(new_cursor + 1)..]
        changed = true
      elsif input.consume_key(KeyCode::Enter)
        new_text = text[0...new_cursor] + "\n" + text[new_cursor..]
        new_cursor += 1
        changed = true
      else
        # Sokol delivers Enter as a '\r' CHAR event too — strip it so
        # the key handler above is the only newline source.
        typed = input.text.gsub('\r', "")
        unless typed.empty?
          new_text = text[0...new_cursor] + typed + text[new_cursor..]
          new_cursor += typed.size
          changed = true
        end
      end

      # Cursor movement (after edits so the caret lands correctly);
      # Up/Down/Home/End are line-wise in multiline.
      parts = new_text.split('\n')
      starts = [] of Int32
      start = 0
      parts.each do |part|
        starts << start
        start += part.size + 1
      end
      li = 0
      starts.each_with_index { |s, i| li = i if s <= new_cursor }
      col = new_cursor - starts[li]

      if input.consume_key(KeyCode::Left)
        new_cursor = (new_cursor - 1).clamp(0, new_text.size)
      elsif input.consume_key(KeyCode::Right)
        new_cursor = (new_cursor + 1).clamp(0, new_text.size)
      elsif input.consume_key(KeyCode::Up)
        li = {li - 1, 0}.max
        new_cursor = starts[li] + {col, parts[li].size}.min
      elsif input.consume_key(KeyCode::Down)
        li = {li + 1, parts.size - 1}.min
        new_cursor = starts[li] + {col, parts[li].size}.min
      elsif input.consume_key(KeyCode::Home)
        new_cursor = starts[li]
      elsif input.consume_key(KeyCode::End)
        new_cursor = starts[li] + parts[li].size
      end

      {new_text, new_cursor, changed}
    end
  end
end
