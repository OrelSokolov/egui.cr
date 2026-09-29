# Windows-style numeric spin box (EDIT + updown control): an
# integer-only text field with a pair of up/down arrow buttons bolted
# onto its right edge.
#
# Only digits (and a leading `-` when the range allows negatives) are
# accepted — everything else typed into the field is dropped. The edit
# model follows DragValue: typing builds a buffer, Backspace deletes,
# Enter commits, Escape cancels. Unlike DragValue the up/down arrows
# and the PageUp/PageDown keys commit IMMEDIATELY (Windows semantics:
# the spin buttons change the value live), and losing focus commits
# the buffer instead of discarding it. Clicking an arrow steps once on
# press and then auto-repeats while held; the mouse wheel steps once
# per scroll event while hovering the control.

module Egui
  class NumberInput
    include Widget

    # Auto-repeat: steps per second while an arrow button stays held,
    # and how long the hold must last before the repeats begin
    # (Windows updown: instant first step, then repeats).
    REPEAT_RATE  = 15.0
    REPEAT_DELAY =  0.4

    # Child-id salts: the two arrow buttons, their repeat accumulators.
    UP_SALT   = 0xB0B1_u64
    DOWN_SALT = 0xB0B2_u64
    UP_ACC    = 0xB0B3_u64
    DOWN_ACC  = 0xB0B4_u64

    def initialize(@value : Int32, @range : Range(Int32, Int32)? = nil,
                   @step : Int32 = 1, @prefix : String = "",
                   @suffix : String = "", @focus_id : String? = nil)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts
      memory = ui.ctx.memory
      input = ui.ctx.input
      id = @focus_id ? ui.named_id(@focus_id.not_nil!) : ui.next_widget_id
      up_id = id.child(UP_SALT)
      down_id = id.child(DOWN_SALT)
      up_acc_id = id.child(UP_ACC)
      down_acc_id = id.child(DOWN_ACC)
      memory.use_id(up_acc_id)
      memory.use_id(down_acc_id)

      editing, buffer = edit_state(memory, id)

      # Stable width: the field is sized by the widest value it can
      # show (current value plus the range endpoints) so it doesn't
      # jitter as the number changes; an overlong edit buffer can
      # still grow it for the duration of the edit.
      shown_for_size = editing ? buffer : display_text(@value)
      text_w = fonts.measure(shown_for_size, font_size).x
      if (r = @range)
        text_w = {text_w,
                  fonts.measure(display_text(r.begin), font_size).x,
                  fonts.measure(display_text(r.end), font_size).x}.max
      end

      pad = style.spacing.button_padding
      border = 2.0
      # Spinner column: same 16px width as the classic scrollbar's
      # arrow buttons, so the two native controls match.
      arrow_w = 16.0
      height = {fonts.measure(shown_for_size, font_size).y,
                font_size * Fonts::LINE_H_FACTOR,
                style.spacing.interact_size.y}.max + (pad.y + border) * 2.0
      width = {text_w + (pad.x + border) * 2.0 + arrow_w,
               style.spacing.interact_size.x + arrow_w}.max
      whole = ui.allocate_at_least(Vec2.new(width, height))
      field = Rect.from_min_size(whole.min,
        Vec2.new(whole.width - arrow_w, whole.height))
      col = Rect.from_min_size(
        Pos2.new(whole.right - arrow_w, whole.top), Vec2.new(arrow_w, whole.height))
      up_r = Rect.from_min_size(col.min, Vec2.new(col.width, col.height / 2.0))
      down_r = Rect.from_min_size(Pos2.new(col.left, col.center.y),
        Vec2.new(col.width, col.height / 2.0))

      field_resp = ui.interact(field, id, Sense::Click | Sense::Focusable)
      up_resp = ui.interact(up_r, up_id, Sense::Click)
      down_resp = ui.interact(down_r, down_id, Sense::Click)

      new_value = @value
      changed = false

      # Arrow buttons: press steps once, hold auto-repeats (see
      # #spin_button). Stepping commits immediately — Windows-style —
      # so any pending edit buffer is parsed as the base and cleared.
      delta = spin_button(ui.ctx, up_resp, up_acc_id) -
              spin_button(ui.ctx, down_resp, down_acc_id)
      if delta != 0
        base = editing ? (buffer.to_i32? || @value) : @value
        stepped = clamp(base + delta * @step)
        if stepped != new_value
          new_value = stepped
          changed = true
        end
        cancel_edit(memory, id)
        editing = false
        buffer = ""
      end

      # Mouse wheel: one step per scroll event. The control registers
      # itself as a scroll sink (same arbitration as ScrollArea /
      # TextArea / Plot): the top-most sink under the pointer owns the
      # delta, so a NumberInput inside a ScrollArea eats the wheel
      # instead of stepping AND scrolling its parent.
      memory.register_scroll_area(id, whole, ui.layer)
      if memory.active_scroll_area? == id && !input.scroll.y.zero?
        stepped = clamp(new_value + (input.scroll.y > 0 ? @step : -@step))
        if stepped != new_value
          new_value = stepped
          changed = true
        end
        cancel_edit(memory, id)
        editing = false
        buffer = ""
      end

      # Click focuses the field (typing starts from the next frame).
      if field_resp.pressed? || field_resp.clicked?
        field_resp.request_focus
      end

      if field_resp.has_focus?
        memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_value, changed, buffer =
          handle_keyboard(ui.ctx, id, buffer, new_value, changed)
        editing, buffer = edit_state(memory, id)
      elsif field_resp.lost_focus?
        # Windows commits on kill-focus; a buffer that no longer
        # parses ("-" or empty) is simply dropped.
        if editing && (parsed = buffer.to_i32?)
          new_value = clamp(parsed)
          changed = new_value != @value
        end
        cancel_edit(memory, id)
        editing = false
        buffer = ""
      end

      # --- paint ------------------------------------------------------------
      # Field: the TextEdit look (weak fill, 1px border; focused swaps
      # to the selection stroke like TextEdit does). Column: two
      # square Win95-beveled arrow buttons, the same rendering the
      # classic scrollbar uses — the field's right border doubles as
      # the divider between the two controls.
      visuals = style.visuals
      focused = field_resp.has_focus?
      bg = focused ? visuals.button_active : visuals.button_weak
      stroke_color = focused ? visuals.selection_fill : visuals.button_stroke
      stroke_w = focused ? border : 1.0
      ui.painter.rect(field, 4.0, bg, stroke_color, stroke_w)

      Icons.arrow_button(ui.painter, :up, up_r,
        visuals.button_fill(up_resp.hovered?, up_resp.pressed?),
        visuals.text_color, pressed: up_resp.pressed?)
      Icons.arrow_button(ui.painter, :down, down_r,
        visuals.button_fill(down_resp.hovered?, down_resp.pressed?),
        visuals.text_color, pressed: down_resp.pressed?)

      shown = editing ? buffer : display_text(new_value)
      ui.painter.text(field.left_center + Vec2.new(pad.x + border, 0.0),
        shown, font_size, visuals.text_color)

      response = field_resp
      response.widget_value = new_value.to_f
      response.mark_changed if changed
      response
    end

    private def display_text(value : Int32) : String
      "#{@prefix}#{value}#{@suffix}"
    end

    private def clamp(value : Int32) : Int32
      return value unless r = @range
      value.clamp(r.begin, r.end)
    end

    private def negatives_allowed? : Bool
      @range.nil? || @range.not_nil!.begin < 0
    end

    # The buffer lives in IdTypeMap under the widget id; a "\u{1}"
    # prefix marks "editing" (so typing "-" then clearing stays in edit
    # mode) — the same scheme DragValue uses.
    EDIT_PREFIX = "\u{1}"

    private def edit_state(memory : Memory, id : Id) : {Bool, String}
      cell = memory.data.get_string(id, "")
      cell.starts_with?(EDIT_PREFIX) ? {true, cell[1..]} : {false, ""}
    end

    private def cancel_edit(memory : Memory, id : Id) : Nil
      memory.data.set_string(id, "")
    end

    private def start_edit(memory : Memory, id : Id, buffer : String) : Nil
      memory.data.set_string(id, EDIT_PREFIX + buffer)
    end

    # Digits pass through; a `-` is accepted only as the very first
    # character and only when the range allows negatives.
    private def filter_typed(text : String, buffer : String) : String
      out = buffer
      text.each_char do |ch|
        if ch.ascii_number?
          out += ch
        elsif ch == '-' && out.empty? && negatives_allowed?
          out = "-"
        end
      end
      out
    end

    # One arrow button: the press frame steps once immediately
    # (Windows behavior), then repeats at REPEAT_RATE after
    # REPEAT_DELAY. The accumulator is NaN while the button is up; it
    # goes negative on press (encoding the delay) and accrues dt each
    # held frame — whole steps ≥ 1 fire and are subtracted back.
    # Returns how many steps (0 or more) to apply this frame.
    private def spin_button(ctx : Context, resp : Response,
                            acc_id : Id) : Int32
      acc = ctx.memory.data.get_f64(acc_id, Float64::NAN)
      steps = 0
      if resp.pressed?
        if acc.nan?
          acc = -REPEAT_DELAY * REPEAT_RATE
          steps = 1
        end
        acc += ctx.input.dt * REPEAT_RATE
        whole = acc.floor
        if whole >= 1.0
          steps += whole.to_i
          acc -= whole
        end
        ctx.request_repaint
      else
        acc = Float64::NAN
      end
      ctx.memory.data.set_f64(acc_id, acc)
      steps
    end

    # Returns {value, changed, buffer}. Arrow keys commit immediately;
    # typed digits build the buffer until Enter (or blur) commits.
    private def handle_keyboard(ctx : Context, id : Id, buffer : String,
                                value : Int32, changed : Bool)
      input = ctx.input
      memory = ctx.memory
      editing, saved_buffer = edit_state(memory, id)

      page = input.consume_key(KeyCode::PageUp) ? @step * 10 : input.consume_key(KeyCode::PageDown) ? -@step * 10 : 0
      nudge = input.consume_key(KeyCode::Up) ? @step : input.consume_key(KeyCode::Down) ? -@step : 0

      unless editing
        # Not editing yet: a digit (or an allowed "-") starts an edit
        # session with the typed text as its buffer.
        seed = filter_typed(input.text, "")
        unless seed.empty?
          start_edit(memory, id, seed)
          return value, changed, seed
        end
        total = page + nudge
        if total != 0
          stepped = clamp(value + total)
          return stepped, stepped != value || changed, buffer
        end
        return value, changed, buffer
      end

      # Editing: buffer consumes text/edits until Enter/Escape/blur.
      if input.consume_key(KeyCode::Escape)
        cancel_edit(memory, id)
        return value, false, ""
      end
      if input.consume_key(KeyCode::Enter)
        parsed = buffer.to_i32?
        cancel_edit(memory, id)
        if parsed
          parsed = clamp(parsed)
          return parsed, parsed != value || changed, ""
        end
        return value, changed, ""
      end
      if input.consume_key(KeyCode::Backspace)
        buffer = buffer[0...-1]
      elsif !input.text.empty? && !input.shortcut_modifiers_down?
        buffer = filter_typed(input.text, buffer)
      end

      # Arrows step the buffered value live (Windows commits on spin).
      total = page + nudge
      if total != 0
        parsed = clamp((buffer.to_i32? || value) + total)
        buffer = parsed.to_s
        start_edit(memory, id, buffer)
        return parsed, parsed != value || changed, buffer
      end

      start_edit(memory, id, buffer)
      {value, changed, buffer}
    end
  end
end
