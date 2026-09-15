# Port of egui_upstream/crates/egui/src/widgets/drag_value.rs.
#
# Pointer: drag horizontally/vertically to change the value by `speed`
# per point. Keyboard (phase 3): while focused, digits/`.`/`-` build an
# edit buffer, Backspace deletes, Enter commits, Escape cancels, and
# Up/Down nudge by the step; the arrows are locked away from focus
# navigation while editing (upstream FocusLockFilter).

module Egui
  class DragValue
    include Widget

    def initialize(@value : Float64, @speed : Float64 = 1.0,
                   @prefix : String = "", @suffix : String = "",
                   @format : (Float64 -> String)? = nil)
    end

    def ui(ui : Ui) : Response
      style = ui.style
      font_size = style.font_size
      input = ui.ctx.input
      id = ui.next_widget_id

      # Sizing uses the edit buffer when one is active.
      editing, buffer = edit_state(ui.ctx.memory, id)
      shown = editing ? buffer : display_text
      text_size = ui.ctx.fonts.measure(shown, font_size)

      size = Vec2.new(
        {text_size.x, style.spacing.interact_size.x}.max,
        {text_size.y, style.spacing.interact_size.y}.max)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click_and_drag | Sense::Focusable)
      # Upstream: horizontal resize arrows — the value is dragged
      # sideways (overrides the interact_cursor pointer).
      response.on_hover_and_drag_cursor(CursorIcon::EwResize)

      new_value = @value
      changed = false

      if response.dragged?
        new_value += (response.drag_delta.x - response.drag_delta.y) * @speed
        changed = true
      end

      if response.has_focus?
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_value, changed, buffer = handle_keyboard(
          ui.ctx, id, buffer, new_value, changed)
      elsif response.lost_focus?
        cancel_edit(ui.ctx.memory, id)
        buffer = ""
      end
      visuals = style.visuals
      bg = if response.dragged? || editing
        visuals.button_active
      elsif response.hovered?
        visuals.button_hovered
      else
        nil # plain label look until touched
      end
      ui.painter.rect(rect, 3.0, bg, visuals.button_stroke, 1.0) if bg

      ui.painter.text(rect.left_center, shown, font_size,
        editing ? visuals.selection_fill : visuals.text_color)

      response.widget_value = new_value
      response.mark_changed if changed
      response.paint_focus_ring(5.0)
      response
    end

    private def display_text : String
      body = @format ? @format.not_nil!.call(@value) : Slider.format_value(@value)
      "#{@prefix}#{body}#{@suffix}"
    end

    # The buffer lives in IdTypeMap under the widget id (which survives
    # pruning). A "\u{1}" prefix marks "editing, possibly empty buffer"
    # (so typing "-" then clearing stays in edit mode).
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

    # Returns {value, changed, buffer}.
    private def handle_keyboard(ctx : Context, id : Id, buffer : String,
                                value : Float64, changed : Bool)
      input = ctx.input
      memory = ctx.memory
      editing, saved_buffer = edit_state(memory, id)

      unless editing
        # Not editing yet: any digit starts an edit session.
        if !input.text.empty? && input.text[0].ascii_number? ||
           input.text == "-" || input.text == "."
          buffer = input.text
          start_edit(memory, id, buffer)
          return value, changed, buffer
        end
        # Up/Down nudge by the step.
        step = @speed * 10.0
        if input.consume_key(KeyCode::Up)
          return value + step, true, buffer
        end
        if input.consume_key(KeyCode::Down)
          return value - step, true, buffer
        end
        return value, changed, buffer
      end

      # Editing: buffer consumes text/edits until Enter/Escape.
      if input.consume_key(KeyCode::Escape)
        cancel_edit(memory, id)
        return value, false, ""
      end
      if input.consume_key(KeyCode::Enter)
        parsed = buffer.to_f64?
        cancel_edit(memory, id)
        if parsed
          return parsed, parsed != value, ""
        end
        return value, false, ""
      end
      if input.consume_key(KeyCode::Backspace)
        buffer = buffer[0...-1]
      elsif !input.text.empty?
        buffer += input.text
      end

      if input.consume_key(KeyCode::Up)
        parsed = buffer.to_f64? || value
        parsed += @speed * 10.0
        buffer = Slider.format_value(parsed)
      elsif input.consume_key(KeyCode::Down)
        parsed = buffer.to_f64? || value
        parsed -= @speed * 10.0
        buffer = Slider.format_value(parsed)
      end

      start_edit(memory, id, buffer)
      # No live commit: the buffer becomes the value on Enter only, so
      # Escape can always cancel back to the pre-edit value.
      {value, changed, buffer}
    end
  end
end
