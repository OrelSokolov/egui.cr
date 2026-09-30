# Port of egui_upstream/crates/egui/src/containers/combo_box.rs.
#
# A closed set of String options: a button showing the current
# selection that opens the shared popup system (Foreground layer,
# closes on outside click) with one item per option. Rendering
# flavors: `variant(:button|:plain|:field)`, `overlay` (the list opens
# on top of the button, GTK3-style) and `label("Select option")` — a
# placeholder for the empty selection that also leads the list as the
# zero option (picking it clears back to "").

module Egui
  class ComboBox
    # Rendering flavors for the closed combo:
    #   :button — solid button, the chevron in a separated sub-button
    #             strip (native dropdown look)
    #   :plain  — one rigid solid button, chevron inline at the right
    #             edge — no separation
    #   :field  — text-input look with a raised select button pinned to
    #             the right edge (editable-combo look)
    # `label` pins a placeholder shown while NOTHING is selected
    # (`selected == ""`, GTK3-style "Select option"); once an option is
    # picked it takes the button. The placeholder also leads the popup
    # list as the zero option — picking it clears the selection.
    # `overlay: true` opens the list right ON TOP of the button
    # (GTK3-style) instead of below it.
    # `width` overrides the natural size; `nil` (the default) fits the
    # button to the widest entry plus the arrow zone.
    # `max_height` caps the open list — beyond it the popup scrolls its
    # rows (wheel over the list, scrollbar thumb) and the keyboard walk
    # follows the highlighted row.
    def initialize(@id : String, @selected : String,
                   @options : Array(String), @width : Float64? = nil,
                   @variant : Symbol = :button, @label : String? = nil,
                   @overlay : Bool = false,
                   @max_height : Float64 = 220.0)
    end

    def variant(v : Symbol) : self
      @variant = v
      self
    end

    def label(text : String) : self
      @label = text
      self
    end

    def overlay(flag : Bool = true) : self
      @overlay = flag
      self
    end

    # `on_select` fires with the picked option; returns whether a new
    # option got picked this frame.
    def show(ui : Ui, &on_select : String ->) : Bool
      style = ui.style
      font_size = style.font_size
      # Placeholder while nothing is picked; the selection takes over
      # as soon as one exists.
      display = @selected.empty? ? @label : @selected
      display ||= ""
      fonts = ui.ctx.fonts_for(style.font_family)
      text_size = fonts.measure(display, font_size)
      glyph_h = text_size.y > 0.0 ? text_size.y : font_size * Fonts::LINE_H_FACTOR

      # Native dropdown geometry: the button is as wide as its widest
      # entry (any option or the displayed text) plus padding and the
      # arrow zone, and as tall as a regular button.
      arrow_h = font_size * 0.6
      arrow_zone = arrow_h + 2 * style.spacing.button_padding.x
      if (w = @width)
        width = w
      else
        widest = text_size.x
        @options.each do |option|
          widest = {widest, fonts.measure(option, font_size).x}.max
        end
        width = widest + 2 * style.spacing.button_padding.x + arrow_zone
      end
      height = {glyph_h + 2 * style.spacing.button_padding.y,
        style.spacing.interact_size.y}.max
      rect = ui.allocate_at_least(Vec2.new(width, height))
      id = ui.next_widget_id
      # Focusable like an editable select (SelectBox's field): while
      # focused, Up/Down walk the options and Enter confirms — the
      # arrows are locked so focus navigation can't steal them.
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)
      ctx = ui.ctx
      focused = ctx.memory.focus.has_focus?(id)
      response.request_focus if response.clicked? && !focused
      ctx.memory.focus.lock_arrows(vertical: true) if focused
      picked = false

      # The keyboard-walked row (Up/Down; Enter confirms it) — index
      # into @options (the placeholder zero row is mouse-only). The
      # first press on a CLOSED combo opens the list (GTK-style) with
      # the walk parked on the current selection. Marked used EVERY
      # frame: the frame that OPENS the list writes it before the
      # popup exists, and end-frame pruning would drop the write.
      active_id = Id.from("#{@id}/active")
      ctx.memory.use_id(active_id)
      enter_value : String? = nil
      if focused &&
         (ctx.input.key_pressed?(KeyCode::Down) || ctx.input.key_pressed?(KeyCode::Up))
        opened_now = false
        unless ctx.popup_open?(@id)
          ctx.open_popup(@id)
          ctx.memory.data.set_int(active_id, @options.index(@selected) || 0)
          opened_now = true
        end
        if ctx.input.consume_key(KeyCode::Down)
          ctx.input.consume_key(KeyCode::Up)
          base = ctx.memory.data.get_int(active_id, 0)
          ctx.memory.data.set_int(active_id,
            {base + 1, @options.size - 1}.min) unless opened_now
        elsif ctx.input.consume_key(KeyCode::Up)
          base = ctx.memory.data.get_int(active_id, 1)
          ctx.memory.data.set_int(active_id, {base - 1, 0}.max) unless opened_now
        end
      end
      if ctx.popup_open?(@id) && focused
        idx = ctx.memory.data.get_int(active_id, 0)
                         .clamp(0, {@options.size - 1, 0}.max)
        enter_value = @options[idx]?
      end
      # Enter confirms the walked row.
      if focused && ctx.input.key_pressed?(KeyCode::Enter) &&
         (value = enter_value)
        ctx.input.consume_key(KeyCode::Enter)
        on_select.call(value)
        @selected = value
        ctx.close_popup(@id)
        picked = true
      end

      # Wheel over the closed combo steps the selection: wheel-down is
      # next, wheel-up is previous (clamped at the ends — no wrap).
      # The widget registers as a scroll sink (the same arbitration as
      # ScrollArea / NumberInput), so the delta only arrives while the
      # pointer is over the button; an open popup owns its wheel via
      # its own layer.
      ui.ctx.memory.register_scroll_area(id, rect, ui.layer)
      if !ui.ctx.popup_open?(@id) && !@options.empty? &&
         ui.ctx.memory.active_scroll_area? == id &&
         (dy = ui.ctx.input.scroll.y) != 0.0
        idx = @options.index(@selected)
        # scroll.y > 0 is wheel-down (next), < 0 wheel-up (previous) —
        # the app-wide sign (positive = content scrolls down), the same
        # as ScrollArea / NumberInput.
        stepped = idx ? (idx + (dy > 0 ? 1 : -1)).clamp(0, @options.size - 1)
                  : (dy > 0 ? 0 : nil)
        if (value = stepped.try { |s| @options[s]? }) && value != @selected
          @selected = value
          display = value
          on_select.call(value)
        end
      end

      visuals = style.visuals
      pad_x = style.spacing.button_padding.x
      # The placeholder reads as a hint — faded like TextEdit's.
      text_color = @selected.empty? && @label ? visuals.fade_color(visuals.text_color, 0.55) : visuals.text_color

      case @variant
      when :field
        # Idle text-field frame (TextEdit's look)…
        ui.painter.rect(rect, 4.0, visuals.button_weak,
          visuals.button_stroke, 1.0)
        # …with a raised select button pinned inside the right edge.
        btn = Rect.from_min_size(
          Pos2.new(rect.right - 1.0 - arrow_zone, rect.top + 1.0),
          Vec2.new(arrow_zone, rect.height - 2.0))
        ui.painter.rect(btn, 3.0,
          visuals.button_fill(response.hovered?, response.active?),
          visuals.button_stroke, 1.0)
        arrow_box = Rect.from_min_size(
          Pos2.new(btn.center.x - arrow_h / 2.0,
            rect.center.y - arrow_h / 2.0),
          Vec2.new(arrow_h, arrow_h))
      when :plain
        # One rigid piece: no strip, the chevron sits at the right edge.
        ui.painter.rect(rect, 3.0,
          visuals.button_fill(response.hovered?, response.active?),
          visuals.button_stroke, 1.0)
        arrow_box = Rect.from_min_size(
          Pos2.new(rect.right - pad_x - arrow_h,
            rect.center.y - arrow_h / 2.0),
          Vec2.new(arrow_h, arrow_h))
      else # :button
        ui.painter.rect(rect, 3.0,
          visuals.button_fill(response.hovered?, response.active?),
          visuals.button_stroke, 1.0)

        # The arrow strip: a sub-button of its own pinned inside the
        # right edge (like the system dropdowns) — one fill step
        # stronger than the field and divided from it by a separator
        # stroke. Inset by the 1px outer stroke so it sits inside the
        # frame.
        separator_x = rect.right - 1.0 - arrow_zone
        strip = Rect.from_min_size(Pos2.new(separator_x, rect.top + 1.0),
          Vec2.new(arrow_zone, rect.height - 2.0))
        ui.painter.rect(strip, 3.0,
          visuals.button_fill(true, response.active?))
        ui.painter.line(Pos2.new(separator_x, rect.top + 1.0),
          Pos2.new(separator_x, rect.bottom - 1.0), 1.0, visuals.button_stroke)
        arrow_box = Rect.from_min_size(
          Pos2.new(strip.center.x - arrow_h / 2.0,
            rect.center.y - arrow_h / 2.0),
          Vec2.new(arrow_h, arrow_h))
      end

      # Text flush left, the chevron in its box.
      ui.painter.text(Pos2.new(rect.left + pad_x, rect.center.y),
        display, font_size, text_color, family: style.font_family)
      Icons.draw(ui.painter, :down, arrow_box, visuals.text_color, 2.0)

      # Toggle: a click while open closes (like MenuButton); without
      # this the re-open would also shield the popup from the
      # click-elsewhere close in Memory#end_frame.
      if response.clicked?
        if ui.ctx.popup_open?(@id)
          ui.ctx.close_popup(@id)
        else
          ui.ctx.open_popup(@id)
          # Park the keyboard walk on the current selection (a later
          # Up/Down continues from there).
          ctx.memory.data.set_int(active_id, @options.index(@selected) || 0)
        end
      end

      # GTK3-style `overlay` opens the list right on top of the button;
      # otherwise it hangs below (flipping above near the screen edge).
      # Zero HORIZONTAL padding (SelectBox's full-bleed convention): the
      # rows span the frame edge to edge inside the scroll viewport and
      # their bands read as one solid block; a little vertical padding
      # keeps the first/last row off the frame stroke.
      anchor = @overlay ? rect.min : ui.ctx.dropdown_anchor(@id, rect)
      ui.ctx.popup(@id, anchor, width: rect.width, min_width: rect.width,
        pad: Vec2.new(0.0, 4.0)) do |pop|
        # The placeholder leads the list as the zero option — picking
        # it reports "" (nothing selected) back through `on_select`.
        items = @label ? [{@label.not_nil!, ""}] : [] of Tuple(String, String)
        @options.each { |option| items << {option, option} }

        row_h = {glyph_h + 2 * style.spacing.button_padding.y,
          pop.style.spacing.interact_size.y}.max
        # The list shrinks to its rows and only scrolls past
        # `max_height` — the ScrollArea has no auto-shrink, so the cap
        # is computed from the measured row height.
        list_h = {(items.size * row_h).round, @max_height}.min

        # Follow the highlighted row — ONLY when it moved (the keyboard
        # walk, a reopen). Re-running every frame would fight the
        # wheel: a candidate parked above the fold would snap the
        # offset back right after every user scroll (see SelectBox).
        list_id = Id.from("#{@id}/list")
        followed_id = Id.from("#{@id}/followed")
        if enter_value && (idx = items.index { |_, v| v == enter_value })
          ctx.memory.use_id(followed_id)
          content = ctx.memory.data.get_vec2(list_id.child(0), Egui::Vec2.zero)
          followed = ctx.memory.data.get_int(followed_id, -1)
          # The first frame after an open has no content measurement
          # yet (max_off = 0) — don't mark followed, retry next frame.
          if content.y > list_h && idx != followed
            row_top = idx * row_h
            row_bottom = row_top + row_h
            max_off = content.y - list_h
            off = ctx.memory.data.get_vec2(list_id, Egui::Vec2.zero).y
              .clamp(0.0, max_off)
            off = row_top if row_top < off
            off = row_bottom - list_h if row_bottom > off + list_h
            ctx.memory.data.set_vec2(list_id,
              Vec2.new(0.0, off.clamp(0.0, max_off)))
            ctx.memory.data.set_int(followed_id, idx)
          end
        end
        ScrollArea.new(list_h, id: list_id).show(pop) do |list|
          items.each do |shown, value|
            text_size = fonts.measure(shown, font_size)
            height = {text_size.y + 2 * style.spacing.button_padding.y,
              list.style.spacing.interact_size.y}.max
            natural_w = 2 * style.spacing.button_padding.x + text_size.x
            # Rows span the viewport; a row wider than it still feeds
            # min_rect so the popup's frame measurement stays honest,
            # but the extra width just clips (the combo's own width
            # already fits the widest option by construction).
            row_w = {list.available_width, natural_w}.max
            item_id = list.next_widget_id
            item_rect = Rect.from_min_size(list.cursor,
              Vec2.new(list.available_width, height))
            list.min_rect = list.min_rect.union(
              Rect.from_min_size(list.cursor, Vec2.new(row_w, height)))
            # Stack flush — the spacing is padding INSIDE each row, not
            # a margin gap between rows, so the hover / selection bands
            # are contiguous like a native dropdown.
            list.cursor = list.layout.advance(list.cursor,
              Vec2.new(row_w, height), Vec2.zero)
            item_resp = list.interact(item_rect, item_id, Sense.click)
            # Band priority (SelectBox's): the hover band beats the
            # Enter candidate (the pointer is explicit intent), the
            # Enter candidate beats the current selection (it is what a
            # confirm would apply). The placeholder zero row never
            # counts as "selected": an empty selection highlights
            # nothing.
            if item_resp.hovered?
              list.painter.rect(item_rect, 3.0, visuals.button_hovered)
            elsif !value.empty? && value == enter_value
              list.painter.rect(item_rect, 3.0, visuals.selection_fill)
            elsif !value.empty? && value == @selected
              list.painter.rect(item_rect, 3.0, visuals.button_hovered)
            end
            row_color = value.empty? ? visuals.fade_color(visuals.text_color, 0.55) : visuals.text_color
            list.painter.text(item_rect.left_center +
              Vec2.new(style.spacing.button_padding.x, 0.0),
              shown, font_size, row_color, family: style.font_family)
            if item_resp.clicked?
              on_select.call(value)
              ui.ctx.close_popup(@id)
              picked = true
            end
          end
        end
      end
      picked
    end
  end
end
