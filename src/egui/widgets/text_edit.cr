# Port of egui_upstream/crates/egui/src/widgets/text_edit/ (stage 2:
# single-line WITH selection and clipboard; multi-line and IME follow
# later).
#
# Cursor position and selection anchor are system state (Int32 byte
# indexes under the widget id; anchor -1 = no selection) — they survive
# IdTypeMap pruning like every widget cell. While focused: text edits
# at the cursor (replacing the selection when one exists), Backspace/
# Delete edit around it, Left/Right/Home/End move it (Shift extends the
# selection, Ctrl+A selects everything), Ctrl+C/X/V go through the
# Clipboard system port, Escape drops focus. Clicking places the cursor
# via Galley#x_at, double-clicking selects a word, dragging selects a
# range. The new buffer flows out through Response#widget_text.

module Egui
  class TextEdit
    include Widget

    def initialize(@text : String, @hint : String? = nil)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts
      id = ui.next_widget_id
      anchor_id = id.child(0x5EED_u64)
      # The anchor cell has no #interact of its own — mark it used or
      # end-frame pruning drops the selection every frame.
      ui.ctx.memory.use_id(anchor_id)

      shown = @text.empty? && (hint = @hint) ? hint : @text
      runs = [TextRun.new(shown, font_size)]
      galley = fonts.layout(runs)

      pad = style.spacing.button_padding
      # The border stroke is drawn INSIDE the rect (backend inset), so
      # the layout reserves it on every side: text, selection and caret
      # start past it (upstream expands the frame inner_margin the same
      # way). Reserved at the focused width so focusing doesn't jitter.
      border = 2.0
      inset = Vec2.new(pad.x + border, pad.y + border)
      size = Vec2.new(
        {galley.size.x, style.spacing.interact_size.x}.max + inset.x * 2.0,
        {galley.size.y, style.spacing.interact_size.y}.max + inset.y * 2.0)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id,
        Sense::Click | Sense::Drag | Sense::Focusable)
      # Upstream: text caret cursor over the edit field.
      ui.ctx.set_cursor_icon(CursorIcon::Text) if response.hovered?

      cursor = ui.ctx.memory.data.get_int(id, @text.size).clamp(0, @text.size)
      anchor = ui.ctx.memory.data.get_int(anchor_id, -1)
      new_text = @text
      changed = false

      # Press places the caret immediately (real input); a synthetic
      # same-frame press+release arrives classified as a click and does
      # the same on release. Double-click selects a word.
      if response.pressed? || response.clicked?
        response.request_focus
        if (pos = ui.ctx.input.pointer_pos)
          if response.double_clicked?
            cursor, anchor = word_range(@text, cursor_at(fonts, galley, rect, inset, pos.x))
          else
            cursor = cursor_at(fonts, galley, rect, inset, pos.x)
            anchor = cursor
          end
        end
      end
      # Drag-select: the anchor stays where the press put it, the caret
      # follows the pointer (a drag with no prior press anchors here).
      if response.drag_started? && (pos = ui.ctx.input.pointer_pos) && anchor == -1
        anchor = cursor_at(fonts, galley, rect, inset, pos.x)
      end
      if response.dragged? && (pos = ui.ctx.input.pointer_pos)
        cursor = cursor_at(fonts, galley, rect, inset, pos.x)
      end

      if response.has_focus?
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_text, cursor, anchor, changed =
          handle_keyboard(ui.ctx, @text, cursor, anchor)
        ui.ctx.request_repaint # caret blink
      end
      ui.ctx.memory.data.set_int(id, cursor)
      ui.ctx.memory.data.set_int(anchor_id, anchor)

      visuals = style.visuals
      bg = response.has_focus? ? visuals.button_active : visuals.button_weak
      # Upstream: the focused field paints its own border in the
      # selection stroke color (upstream `visuals.selection.stroke`),
      # not a ring outside the frame — an outside ring both escapes the
      # widget bounds and gets scissored by the parent clip.
      stroke_color = response.has_focus? ? visuals.selection_fill : visuals.button_stroke
      stroke_w = response.has_focus? ? border : 1.0
      ui.painter.rect(rect, 4.0, bg, stroke_color, stroke_w)

      inner = rect.min + inset
      color = if @text.empty? && @hint
                visuals.fade_color(visuals.text_color, 0.55)
              else
                visuals.text_color
              end

      # Selection highlight behind the text (the galley is laid out on
      # the actual text, never the hint).
      sel_min = {cursor, anchor}.min
      sel_max = {cursor, anchor}.max
      if anchor >= 0 && anchor != cursor && !@text.empty?
        x0 = galley.x_at(0, sel_min, fonts)
        x1 = galley.x_at(0, sel_max, fonts)
        top = inner.y + 1.0
        height = {galley.size.y - 2.0, 2.0}.max
        ui.painter.rect(
          Rect.from_min_size(Pos2.new(inner.x + x0, top),
            Vec2.new(x1 - x0, height)),
          2.0, visuals.selection_fill)
      end

      ui.painter.paint_galley(inner, galley, fonts, color)

      # Blinking caret (1s period) while focused. An empty field with
      # no hint lays out to a zero-height galley (no rows) — fall back
      # to the line height so the caret stays full-size until the
      # first character gives the galley a real row.
      line_h = {galley.size.y, font_size * Fonts::LINE_H_FACTOR}.max
      if response.has_focus? && (ui.ctx.input.time % 1.0) < 0.6
        caret_x = inner.x + galley.x_at(0, cursor, fonts)
        top = inner.y + 1.0
        bottom = inner.y + line_h - 1.0
        ui.painter.line(Pos2.new(caret_x, top), Pos2.new(caret_x, bottom),
          1.0, visuals.text_color)
      end

      response.widget_text = new_text
      response.mark_changed if changed
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

    # Word around `pos` for double-click selection: ASCII letters and
    # digits group together (byte indexes, like the rest of the widget).
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

    # Returns {text, cursor, anchor, changed}.
    private def handle_keyboard(ctx : Context, text : String, cursor : Int32,
                                anchor : Int32)
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

      # Clipboard through the system port; single-line paste strips
      # line breaks. With Ctrl held no other key has meaning here.
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
            # Single-line field: line breaks become spaces (upstream
            # single_line_textedit behavior).
            paste = paste.gsub(/\r\n|\r|\n/, " ")
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

      # Selection-aware edits.
      if input.consume_key(KeyCode::Backspace)
        if has_sel
          new_text = text[0...sel_min] + text[sel_max..]
          new_cursor = new_anchor = sel_min
        elsif cursor > 0
          new_text = text[0...(cursor - 1)] + text[cursor..]
          new_cursor = new_anchor = cursor - 1
        end
        changed = new_text != text
      elsif input.consume_key(KeyCode::Delete)
        if has_sel
          new_text = text[0...sel_min] + text[sel_max..]
          new_cursor = new_anchor = sel_min
        elsif cursor < text.size
          new_text = text[0...cursor] + text[(cursor + 1)..]
          new_anchor = cursor
        end
        changed = new_text != text
      elsif !input.text.empty? && !input.any_modifier_down?
        insert_at = has_sel ? sel_min : cursor
        tail = has_sel ? text[sel_max..] : text[cursor..]
        new_text = text[0...insert_at] + input.text + tail
        new_cursor = new_anchor = insert_at + input.text.size
        changed = true
      end

      # Cursor movement (after edits so the caret lands correctly);
      # Shift extends the selection by pinning the anchor, plain arrows
      # collapse it — entering a selected range from its near edge
      # (upstream semantics: plain Left on a selection goes to the
      # start edge, Right to the end edge, without moving past it).
      if input.consume_key(KeyCode::Left)
        if input.modifiers.shift
          new_anchor = new_cursor if new_anchor == -1
          new_cursor = (new_cursor - 1).clamp(0, new_text.size)
        elsif new_anchor >= 0 && new_anchor != new_cursor
          new_cursor = new_anchor = {new_cursor, new_anchor}.min
        else
          new_cursor = (new_cursor - 1).clamp(0, new_text.size)
          new_anchor = new_cursor
        end
      elsif input.consume_key(KeyCode::Right)
        if input.modifiers.shift
          new_anchor = new_cursor if new_anchor == -1
          new_cursor = (new_cursor + 1).clamp(0, new_text.size)
        elsif new_anchor >= 0 && new_anchor != new_cursor
          new_cursor = new_anchor = {new_cursor, new_anchor}.max
        else
          new_cursor = (new_cursor + 1).clamp(0, new_text.size)
          new_anchor = new_cursor
        end
      elsif input.consume_key(KeyCode::Home) ||
            input.consume_key(KeyCode::Up)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        new_cursor = 0
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(KeyCode::End) ||
            input.consume_key(KeyCode::Down)
        new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
        new_cursor = new_text.size
        new_anchor = new_cursor unless input.modifiers.shift
      end

      {new_text, new_cursor, new_anchor, changed}
    end
  end
end
