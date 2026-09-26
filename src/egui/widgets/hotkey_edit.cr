# Hotkey capture button (egui.cr's own widget — no upstream
# equivalent, see docs/ANALYSIS.md §12).
#
# Shows the hotkey bound to an action in `ctx.hotkeys` (or "(not
# bound)"). A click starts capture — "press keys…" — and the next
# non-modifier key press, with whatever modifiers are held, becomes
# the action's new binding (Escape cancels, Backspace/Delete clears
# it). While capturing, global hotkey dispatch pauses
# (`Context#hotkey_capture_active!`) and every pressed key is
# consumed so no other widget reacts. The new binding flows out
# through the on_change block; menus display it next frame because
# they read the same map.

module Egui
  class HotkeyEdit
    include Widget

    def initialize(@action : HotkeyAction, &@on_change : Hotkey? ->)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts
      hotkeys = ui.ctx.hotkeys
      input = ui.ctx.input

      id = ui.next_widget_id
      # Capture flag is system state (survives IdTypeMap pruning).
      cell = id.child(0xB1DF_u64)
      ui.ctx.memory.use_id(cell)
      capturing = ui.ctx.memory.data.get_bool(cell)

      bound = hotkeys.hotkey_for(@action)
      text_size_worst = fonts.measure("press keys…", font_size)
      pad = style.spacing.button_padding
      size = Vec2.new(
        {text_size_worst.x + 2 * pad.x, 90.0}.max,
        {text_size_worst.y, style.spacing.interact_size.y}.max + 2 * pad.y)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click)

      # Click toggles capture; a click anywhere else cancels it.
      if response.clicked?
        capturing = !capturing
      elsif capturing && input.pointer_pressed?
        capturing = false
      end

      new_value : Hotkey? = nil
      value_changed = false
      if capturing
        # Pause global dispatch next frame and swallow every key so
        # the combo being recorded triggers nothing.
        ui.ctx.hotkey_capture_active!
        if input.consume_key(KeyCode::Escape)
          capturing = false
        elsif input.consume_key(KeyCode::Backspace) ||
              input.consume_key(KeyCode::Delete)
          hotkeys.unbind_action(@action)
          new_value = nil
          value_changed = true
          capturing = false
        elsif (key = input.keys_pressed.find { |k| input.consume_key(k) })
          hotkey = Hotkey.new(key, input.modifiers)
          hotkeys.bind(hotkey, @action)
          new_value = hotkey
          value_changed = true
          capturing = false
        end
        input.keys_pressed.each { |k| input.consume_key(k) }
        ui.ctx.request_repaint
      end
      ui.ctx.memory.data.set_bool(cell, capturing)
      bound = new_value if value_changed && new_value
      @on_change.call(new_value) if value_changed

      shown = if capturing
                "press keys…"
              elsif bound
                bound.to_s
              else
                "(not bound)"
              end
      text_size = fonts.measure(shown, font_size)

      visuals = style.visuals
      if capturing
        ui.painter.rect(rect, 4.0, visuals.selection_fill,
          stroke_color: visuals.selection_fill, stroke_width: 2.0)
      else
        ui.painter.rect(rect, 4.0,
          visuals.button_fill(response.hovered?, response.active?),
          stroke_color: visuals.button_stroke, stroke_width: 1.0)
      end
      color = capturing || bound ? visuals.text_color :
               visuals.fade_color(visuals.text_color, 0.55)
      ui.painter.text(
        Pos2.new(rect.center.x - text_size.x / 2.0, rect.center.y),
        shown, font_size, color)

      response
    end
  end

  class Ui
    # Hotkey capture button bound to `action` in ctx.hotkeys; the block
    # fires with the new binding (nil = cleared) — the map is already
    # updated, the block is for side effects like persisting settings.
    def hotkey_edit(action : HotkeyAction, &on_change : Hotkey? ->) : Response
      add(HotkeyEdit.new(action, &on_change))
    end
  end
end
