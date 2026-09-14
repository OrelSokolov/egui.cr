# Port of egui_upstream/crates/egui/src/widgets/text_edit/ (stage 1:
# single-line, no selection/clipboard/IME — those follow in phase 7).
#
# Cursor position is system state (Int32 char index under the widget
# id, survives IdTypeMap pruning like every widget cell). While
# focused: text inserts at the cursor, Backspace/Delete edit around
# it, Left/Right/Home/End move it (arrows locked away from focus
# navigation), Escape drops focus. Clicking places the cursor via
# Galley#x_at. The new buffer flows out through Response#widget_text.

module Egui
  class TextEdit
    include Widget

    def initialize(@text : String, @hint : String? = nil)
    end

    def ui(ui : Ui) : Response
      style = ui.style
      font_size = style.font_size
      fonts = ui.ctx.fonts
      id = ui.next_widget_id

      shown = @text.empty? && (hint = @hint) ? hint : @text
      runs = [TextRun.new(shown, font_size)]
      galley = fonts.layout(runs)

      pad = Vec2.new(6.0, 4.0)
      size = Vec2.new(
        {galley.size.x, style.spacing.interact_size.x}.max + pad.x * 2.0,
        {galley.size.y, style.spacing.interact_size.y}.max + pad.y * 2.0)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

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
      ui.painter.rect(rect, 4.0, bg, visuals.button_stroke, 1.0)

      inner = rect.min + pad
      color = @text.empty? && @hint ? visuals.text_color.mul_color(0.5) : visuals.text_color
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
  end
end
