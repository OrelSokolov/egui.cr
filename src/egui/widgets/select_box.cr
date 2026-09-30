# A searchable select (editable combo): the CLOSED widget is a text
# field showing the current selection — typing right in it filters the
# dropdown list that hangs below (native "combobox with entry"
# behavior, the way system font pickers work). The chevron strip on
# the right toggles the full, unfiltered list; picking a row applies
# the value, closes the list and leaves the field showing it.
#
# The edit buffer is persistent per-widget state (IdTypeMap under
# "#{id}/buf") so typing survives list toggles; picking (or the
# placeholder row) rewrites it to the new value.

module Egui
  class SelectBox
    # `label` pins a placeholder shown while NOTHING is selected
    # (`selected == ""`, like TextEdit's hint); it also leads the
    # dropdown as the zero option — picking it reports "".
    # `width` defaults to a fixed column (no measure-every-option pass
    # — the option list is too long for that to be cheap).
    # `max_height` caps the dropdown's scroll viewport.
    def initialize(@id : String, @selected : String,
                   @options : Array(String), @width : Float64? = nil,
                   @label : String? = nil,
                   @max_height : Float64 = 220.0)
    end

    def label(text : String) : self
      @label = text
      self
    end

    # `on_select` fires with the picked option ("" for the placeholder
    # row); returns whether a new option got picked this frame.
    def show(ui : Ui, &on_select : String ->) : Bool
      ctx = ui.ctx
      style = ui.style
      font_size = style.font_size
      buf_id = Id.from("#{@id}/buf")
      # The buffer cell is written by the on_change below but read here
      # only — mark it used or end-frame IdTypeMap pruning drops it
      # every frame (the field would forget what was typed).
      ctx.memory.use_id(buf_id)
      buffer = ctx.memory.data.get_string(buf_id, @selected)

      arrow_h = font_size * 0.6
      pad = style.spacing.button_padding
      width = @width || 160.0
      glyph_h = font_size * Fonts::LINE_H_FACTOR
      height = {glyph_h + 2 * pad.y, style.spacing.interact_size.y}.max
      arrow_zone = arrow_h + 2 * pad.x

      rect = ui.allocate_at_least(Vec2.new(width, height))
      id = ui.next_widget_id
      response = ui.interact(rect, id, Sense.click)
      visuals = style.visuals

      # The selector IS the search field: it spans the frame minus the
      # chevron strip, embedded FRAMELESS (TextEdit `frame: false`) —
      # the selector draws the ONE frame; a nested frame with its own
      # stroke would read as an input glued on top of a box.
      field = Rect.from_min_size(rect.min,
        Vec2.new(width - arrow_zone - 2.0, rect.height))
      picked = false
      field_ui = ui.child_ui(field, Id.from("#{@id}/field"))
      field_id = field_ui.named_id("field")
      # The keyboard-walked row (Up/Down; see the navigation block
      # below) — index into the filtered OPTION rows (the placeholder
      # zero row is mouse-only). Reset to the current selection when
      # the list opens, to the top when the filter changes. Marked
      # used EVERY frame (not just while open): the frame that OPENS
      # the list writes it before the popup exists, and end-frame
      # pruning would drop the write.
      active_id = Id.from("#{@id}/active")
      ctx.memory.use_id(active_id)
      focused = ctx.memory.focus.has_focus?(field_id)

      # One frame for the whole widget (ComboBox :field's look), with
      # the standalone TextEdit's focus treatment: a focused field
      # takes the selection stroke as its border.
      ui.painter.rect(rect, 4.0,
        focused ? visuals.button_active : visuals.button_weak,
        focused ? visuals.selection_fill : visuals.button_stroke,
        focused ? 2.0 : 1.0)
      strip = Rect.from_min_size(
        Pos2.new(rect.right - 1.0 - arrow_zone, rect.top + 1.0),
        Vec2.new(arrow_zone, rect.height - 2.0))
      strip_hover = (pos = ctx.input.pointer_pos) ? strip.contains?(pos) : false
      ui.painter.rect(strip, 3.0,
        visuals.button_fill(strip_hover, strip_hover && response.active?),
        visuals.button_stroke, 1.0)
      ui.painter.line(Pos2.new(strip.left, rect.top + 1.0),
        Pos2.new(strip.left, rect.bottom - 1.0), 1.0, visuals.button_stroke)
      Icons.draw(ui.painter, :down,
        Rect.from_min_size(
          Pos2.new(strip.center.x - arrow_h / 2.0,
            rect.center.y - arrow_h / 2.0),
          Vec2.new(arrow_h, arrow_h)), visuals.text_color, 2.0)

      # Up/Down walk the highlighted (Enter) row — handled BEFORE the
      # embedded edit sees the keys (it maps Up/Down to Home/End for
      # its caret). The first press on a CLOSED box opens the list
      # (GTK-style) with the walk parked on the current selection.
      if focused &&
         (ctx.input.key_pressed?(KeyCode::Down) || ctx.input.key_pressed?(KeyCode::Up))
        opened_now = false
        unless ctx.popup_open?(@id)
          ctx.memory.data.set_string(buf_id, @selected) # full list
          ctx.open_popup(@id)
          reset_active_to_selection(ctx)
          opened_now = true
        end
        if ctx.input.consume_key(KeyCode::Down)
          ctx.input.consume_key(KeyCode::Up)
          unless opened_now
            matches = filtered_matches(buffer)
            base = ctx.memory.data.get_int(active_id, 0)
            ctx.memory.data.set_int(active_id,
              {base + 1, matches.size - 1}.min)
          end
        elsif ctx.input.consume_key(KeyCode::Up)
          base = ctx.memory.data.get_int(active_id, 1)
          ctx.memory.data.set_int(active_id, {base - 1, 0}.max) unless opened_now
        end
      end

      # Wheel over the closed box steps the selection: wheel-down is
      # next, wheel-up is previous (clamped at the ends — no wrap).
      # The widget registers as a scroll sink (the same arbitration as
      # ScrollArea / NumberInput), so the delta only arrives while the
      # pointer is over the field; an open list owns its wheel itself
      # (its ScrollArea sits on a higher layer). With nothing selected
      # wheel-down picks the first option; wheel-up has nothing to
      # step back to.
      ctx.memory.register_scroll_area(id, rect, ui.layer)
      if !ctx.popup_open?(@id) && !@options.empty? &&
         ctx.memory.active_scroll_area? == id &&
         (dy = ctx.input.scroll.y) != 0.0
        idx = @options.index(@selected)
        # scroll.y > 0 is wheel-down (next), < 0 wheel-up (previous) —
        # the app-wide sign (positive = content scrolls down), the same
        # as ScrollArea / NumberInput.
        stepped = idx ? (idx + (dy > 0 ? 1 : -1)).clamp(0, @options.size - 1)
                  : (dy > 0 ? 0 : nil)
        if (value = stepped.try { |s| @options[s]? }) && value != @selected
          @selected = value
          on_select.call(value)
          # The field shows the buffer: rewrite it to the new value
          # (clearing any stale filter) and park the keyboard walk
          # there, BEFORE the edit renders so it updates this frame.
          ctx.memory.data.set_string(buf_id, value)
          ctx.memory.data.set_int(active_id, stepped.not_nil!)
          buffer = value
        end
      end

      field_resp = field_ui.text_edit_singleline(buffer, hint: @label || @selected,
        focus_id: "field", frame: false) do |text|
        ctx.memory.data.set_string(buf_id, text)
        # Typing narrows the list from the TOP match (and asks for one
        # follow pass to bring it into view)…
        ctx.memory.data.set_int(active_id, 0)
        ctx.memory.data.set_int(Id.from("#{@id}/followed"), -1)
        # …and opens it; an already-open list stays open.
        ctx.open_popup(@id) unless text.strip == @selected
      end
      # A click on the field's empty tail (past the text — TextEdit
      # sizes to the natural width, so its own rect ends early) must
      # still focus the field: the whole field is the search entry.
      tail_click = response.clicked? && !strip_hover
      if tail_click && !ctx.memory.focus.has_focus?(field_id)
        ctx.memory.focus.request(field_id)
      end
      # Select-all on entry (URL-bar behavior), seeded in the frame the
      # focus is REQUESTED so it is active when focus lands the next
      # frame: the first keystroke replaces the value instead of
      # appending to it. (Seeding on `gained_focus?` would run AFTER
      # that first keystroke's edit and eat the second character.)
      if field_resp.clicked? || tail_click
        ctx.memory.data.set_int(field_id, buffer.size)
        ctx.memory.data.set_int(field_id.child(0x5EED_u64), 0)
        # A click on the field opens the FULL list too (combo
        # semantics) — typing from here narrows it. The walk starts on
        # the current selection.
        unless ctx.popup_open?(@id)
          ctx.open_popup(@id)
          reset_active_to_selection(ctx)
        end
      end
      # A keystroke THIS frame already rewrote the cell — filter by the
      # fresh value, not the frame-start one.
      buffer = ctx.memory.data.get_string(buf_id, @selected)

      # The strip toggles the full list; a click on the closed field
      # also opens it (and focuses the field for typing).
      if response.clicked? && strip_hover
        if ctx.popup_open?(@id)
          ctx.close_popup(@id)
        else
          ctx.memory.data.set_string(buf_id, @selected) # full list
          ctx.open_popup(@id)
          reset_active_to_selection(ctx)
        end
      end

      # Enter confirms — the field's edit is single-line and ignores
      # the key, so it is free to commit the pick: with the list open,
      # the first matching option (the current selection when nothing
      # was typed yet); with it closed, an option the buffer names
      # exactly. Nil = nothing to confirm; the key stays unconsumed.
      if ctx.memory.focus.has_focus?(field_id) &&
         ctx.input.key_pressed?(KeyCode::Enter) &&
         (value = enter_pick(ctx, buffer))
        ctx.input.consume_key(KeyCode::Enter)
        on_select.call(value)
        @picked_value = value
        ctx.memory.data.set_string(buf_id, value)
        ctx.close_popup(@id)
        picked = true
      end

      anchor = ctx.dropdown_anchor(@id, rect)
      # Zero HORIZONTAL padding (ComboBox's full-bleed convention): the
      # rows span the frame edge to edge and their bands read as one
      # solid block; a little vertical padding keeps the first/last
      # row off the frame stroke.
      ctx.popup(@id, anchor, width: rect.width, min_width: rect.width,
        pad: Vec2.new(0.0, 4.0)) do |pop|
        picked = render_list(ctx, pop, rect, font_size, buffer,
          enter_pick(ctx, buffer), &on_select)
        # A pick leaves the field showing what was picked (the value —
        # "" for the placeholder row → the hint shows again).
        if picked && (value = @picked_value)
          ctx.memory.data.set_string(buf_id, value)
        end
      end
      picked
    end

    # The value the last pick reported ("" for the placeholder row);
    # nil until a pick happens inside #render_list this frame.
    @picked_value : String? = nil

    # What Enter confirms. List OPEN: the keyboard-walked row (see the
    # navigation block in #show) — which opens parked on the current
    # selection, so an untouched list confirms what it shows. List
    # CLOSED: the option the buffer names exactly (case-insensitive) —
    # a value typed out in full commits without opening anything.
    # Nil = nothing to confirm.
    private def enter_pick(ctx : Context, buffer : String) : String?
      needle = buffer.strip.downcase
      current = @selected.strip.downcase
      if ctx.popup_open?(@id)
        matches = filtered_matches(needle)
        idx = ctx.memory.data.get_int(Id.from("#{@id}/active"), 0)
               .clamp(0, {matches.size - 1, 0}.max)
        matches[idx]?
      else
        return nil if needle.empty? || needle == current
        filtered_matches(needle).find { |o| o.downcase == needle }
      end
    end

    # The OPTION rows the needle leaves (the placeholder zero row is
    # not part of the walk): everything when the filter is untouched,
    # the substring matches otherwise.
    private def filtered_matches(needle : String) : Array(String)
      n = needle.strip.downcase
      return @options if n.empty? || n == @selected.strip.downcase
      @options.select { |o| o.downcase.includes?(n) }
    end

    # Park the keyboard walk on the current selection (list opening) —
    # and ask for one follow-scroll pass: the walk/follow bookkeeping
    # is stale from the previous open.
    private def reset_active_to_selection(ctx : Context) : Nil
      ctx.memory.data.set_int(Id.from("#{@id}/active"),
        @options.index(@selected) || 0)
      ctx.memory.data.set_int(Id.from("#{@id}/followed"), -1)
    end

    private def render_list(ctx : Context, pop : Ui, button : Rect,
                            font_size : Float64, buffer : String,
                            enter_value : String?,
                            &on_select : String ->) : Bool
      style = pop.style
      visuals = style.visuals
      @picked_value = nil

      # The visible rows: the placeholder zero option (when one is
      # given) + the filtered option rows — the same set the keyboard
      # walk and enter_pick address (minus the placeholder).
      shown = @label ? [{@label.not_nil!, ""}] : [] of Tuple(String, String)
      filtered_matches(buffer).each { |option| shown << {option, option} }

      picked = false
      row_h = {font_size * Fonts::LINE_H_FACTOR +
        2 * style.spacing.button_padding.y,
        style.spacing.interact_size.y}.max
      # ComboBox row convention: the spacing is padding INSIDE each
      # row, rows stack FLUSH (zero gap) so the hover/selection bands
      # read as one contiguous strip, native-dropdown style.
      step = row_h

      # Follow the highlighted row - ONLY when it moved (the keyboard
      # walk, a filter change, a reopen). Re-running every frame would
      # fight the wheel: a candidate parked above the fold would snap
      # the offset back to the top right after every user scroll.
      list_id = Id.from("#{@id}/list")
      followed_id = Id.from("#{@id}/followed")
      if enter_value && (idx = shown.index { |_, v| v == enter_value })
        ctx.memory.use_id(followed_id)
        content = ctx.memory.data.get_vec2(list_id.child(0), Egui::Vec2.zero)
        followed = ctx.memory.data.get_int(followed_id, -1)
        # The first frame after an open has no content measurement yet
        # (max_off = 0) - don't mark followed, retry next frame.
        if content.y > @max_height && idx != followed
          row_top = idx * step
          row_bottom = row_top + row_h
          max_off = content.y - @max_height
          off = ctx.memory.data.get_vec2(list_id, Egui::Vec2.zero).y
            .clamp(0.0, max_off)
          off = row_top if row_top < off
          off = row_bottom - @max_height if row_bottom > off + @max_height
          ctx.memory.data.set_vec2(list_id,
            Vec2.new(0.0, off.clamp(0.0, max_off)))
          ctx.memory.data.set_int(followed_id, idx)
        end
      end
      ScrollArea.new(@max_height, id: list_id).show(pop) do |list|
        shown.each do |label, value|
          item_id = list.next_widget_id
          item_rect = Rect.from_min_size(list.cursor,
            Vec2.new(list.available_width, row_h))
          list.min_rect = list.min_rect.union(item_rect)
          list.cursor = list.layout.advance(list.cursor,
            Vec2.new(list.available_width, row_h), Vec2.zero)
          item_resp = list.interact(item_rect, item_id, Sense.click)
          # Band priority: the hover band beats the Enter candidate
          # (the pointer is explicit intent), the Enter candidate beats
          # the current selection (it is what a confirm would apply).
          if item_resp.hovered?
            list.painter.rect(item_rect, 3.0, visuals.button_hovered)
          elsif !value.empty? && value == enter_value
            list.painter.rect(item_rect, 3.0, visuals.selection_fill)
          elsif !value.empty? && value == @selected
            list.painter.rect(item_rect, 3.0, visuals.button_hovered)
          end
          row_color = value.empty? ?
            visuals.fade_color(visuals.text_color, 0.55) : visuals.text_color
          list.painter.text(item_rect.left_center +
            Vec2.new(style.spacing.button_padding.x, 0.0),
            label, font_size, row_color, family: style.font_family)
          if item_resp.clicked?
            on_select.call(value)
            @picked_value = value
            ctx.close_popup(@id)
            picked = true
          end
        end
        if shown.empty?
          line = Vec2.new(list.available_width,
            font_size * Fonts::LINE_H_FACTOR + 2 * style.spacing.button_padding.y)
          empty = list.allocate_space(line)
          list.painter.text(
            Pos2.new(empty.left + style.spacing.button_padding.x,
              empty.center.y),
            "no matches", font_size,
            visuals.fade_color(visuals.text_color, 0.5),
            family: style.font_family)
        end
      end
      picked
    end
  end
end
