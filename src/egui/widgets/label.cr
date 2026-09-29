# Port of egui_upstream/crates/egui/src/widgets/label.rs.
#
# A Label reserves its text size and paints the text. Accepts a String
# or RichText. `wrap` is tri-state (upstream `MaybeWrap`): nil (default)
# wraps a label on its own line in a vertical layout against the
# available width, `true` wraps always, `false` never. Wrapping is
# greedy by words, with a per-character fallback when a single word
# is longer than the whole width.
#
# Selectable by default (`userselect: true`, upstream
# `interaction.selectable_labels`): the label senses click+drag, a
# press places the caret, dragging selects a range, double-click
# selects a word, and Ctrl+C copies the selection through the
# Clipboard system port while no widget holds keyboard focus.
# `userselect: false` reverts to the inert paint-only label (upstream
# `Sense::hover()`).

module Egui
  class Label
    include Widget

    getter rich : RichText
    getter wrap : Bool?
    getter? userselect : Bool

    def initialize(text : String, size : Float64? = nil, wrap : Bool? = nil,
                   userselect : Bool = true, id : String? = nil)
      @rich = RichText.new(text)
      @rich.size(size) if size
      @wrap = wrap
      @userselect = userselect
      @id_name = id
    end

    def initialize(@rich : RichText, wrap : Bool? = nil,
                   userselect : Bool = true, id : String? = nil)
      @wrap = wrap
      @userselect = userselect
      @id_name = id
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike
    end

    def inspector_label : String?
      @rich.text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      runs = @rich.runs(style.font_size, style.visuals.text_color)
      # Default (nil): wrap only where the label owns the rest of the
      # line — a vertical layout (upstream `TextWrapMode::Wrap`); a
      # label inside a horizontal row stays inline (`Extend`). A zero
      # remaining width would char-break every glyph onto its own row —
      # treat it as unbounded instead.
      wrap = @wrap.nil? ? ui.layout.vertical? : @wrap
      available = ui.available_width
      max_width = wrap && available > 0.0 ? available : nil
      galley = ui.ctx.fonts.layout(runs, max_width)

      rect = ui.allocate_at_least(galley.size)
      response = ui.interact(rect, id,
        @userselect ? Sense.click_and_drag : Sense.none)

      if @userselect
        paint_selectable(ui, response, id, rect, galley, style)
      else
        ui.painter.paint_galley(rect.min, galley, ui.ctx.fonts,
          style.visuals.text_color)
      end

      response
    end

    # Text selection — a single-label slice of upstream
    # LabelSelectionState: cursor and anchor are system state (Int32
    # byte indexes under the widget id; anchor -1 = no selection),
    # exactly like TextEdit. Selection highlights paint per row behind
    # the galley; the flattened row text ('\n' is dropped by layout)
    # carries the indexes.
    private def paint_selectable(ui : Ui, response : Response, id : Id,
                                 rect : Rect, galley : Galley,
                                 style : Style) : Nil
      ctx = ui.ctx
      fonts = ctx.fonts
      anchor_id = id.child(0x5EED_u64)
      # The anchor cell has no #interact of its own — mark it used or
      # end-frame pruning drops the selection every frame.
      ctx.memory.use_id(anchor_id)

      flat = galley.rows.map(&.text).join
      row_starts = [] of Int32
      start = 0
      galley.rows.each do |row|
        row_starts << start
        start += row.text.size
      end

      cursor = ctx.memory.data.get_int(id, 0).clamp(0, flat.size)
      anchor = ctx.memory.data.get_int(anchor_id, -1).clamp(-1, flat.size)

      ctx.set_cursor_icon(CursorIcon::Text) if response.hovered?

      # A press anywhere else (or Escape with nothing focused) ends
      # this label's selection (upstream deselects the same way).
      if ctx.input.pointer_pressed? && !response.hovered?
        anchor = -1
      elsif anchor >= 0 && anchor != cursor && ctx.memory.focus.id.nil? &&
            ctx.input.consume_key(KeyCode::Escape)
        anchor = -1
      end

      # Press places the caret immediately; double-click selects a
      # word (real input or a synthetic same-frame press+release).
      if (response.pressed? || response.clicked?) &&
         (pos = ctx.input.pointer_pos)
        if response.double_clicked?
          cursor, anchor = word_range(flat,
            cursor_at(galley, row_starts, rect, pos, fonts))
        else
          cursor = anchor = cursor_at(galley, row_starts, rect, pos, fonts)
        end
      end
      # Drag-select: the anchor stays where the press put it, the
      # caret follows the pointer (a drag with no prior press anchors
      # here).
      if response.drag_started? && (pos = ctx.input.pointer_pos) && anchor == -1
        anchor = cursor_at(galley, row_starts, rect, pos, fonts)
      end
      if response.dragged? && (pos = ctx.input.pointer_pos)
        cursor = cursor_at(galley, row_starts, rect, pos, fonts)
      end

      # Ctrl+C copies the selection — only while no widget holds
      # keyboard focus (a focused TextEdit owns the clipboard), and
      # #consume_key picks the first label with a selection.
      if anchor >= 0 && anchor != cursor && ctx.memory.focus.id.nil? &&
         ctx.input.modifiers.ctrl && ctx.input.consume_key(KeyCode::C)
        sel_min = {cursor, anchor}.min
        sel_max = {cursor, anchor}.max
        Egui::SystemPorts::Clipboard.text =
          original_slice(@rich.text, sel_min, sel_max)
      end

      ctx.memory.data.set_int(id, cursor)
      ctx.memory.data.set_int(anchor_id, anchor)

      visuals = style.visuals
      if anchor >= 0 && anchor != cursor && !flat.empty?
        sel_min = {cursor, anchor}.min
        sel_max = {cursor, anchor}.max
        galley.rows.each_with_index do |row, i|
          row_start = row_starts[i]
          lo = {sel_min, row_start}.max
          hi = {sel_max, row_start + row.text.size}.min
          if lo < hi
            x0 = galley.x_at(i, lo - row_start, fonts)
            x1 = galley.x_at(i, hi - row_start, fonts)
            ui.painter.rect(Rect.from_min_size(
              Pos2.new(rect.left + x0, rect.top + row.y + 1.0),
              Vec2.new(x1 - x0, row.height - 2.0)),
              0.0, visuals.selection_fill)
          end
        end
      end
      ui.painter.paint_galley(rect.min, galley, fonts, visuals.text_color)
    end

    # Byte index of the pointer inside the flattened row text: the row
    # under the pointer (y), then the nearest x boundary within it.
    private def cursor_at(galley : Galley, row_starts : Array(Int32),
                          rect : Rect, pos : Pos2, fonts : Fonts) : Int32
      return 0 if galley.rows.empty?
      local_x = pos.x - rect.left
      local_y = pos.y - rect.top
      row_index = 0
      galley.rows.each_with_index do |row, i|
        row_index = i
        break if local_y < row.y + row.height
      end
      row = galley.rows[row_index]
      text = row.text
      return row_starts[row_index] + text.size if local_x >= row.width
      best = text.size
      text.size.times do |i|
        best = i
        break if galley.x_at(row_index, i, fonts) >= local_x
      end
      row_starts[row_index] + best
    end

    # Selection indexes live in the flattened row text ('\n' is dropped
    # by layout); map them back onto the source text for copying.
    private def original_slice(text : String, min : Int32,
                               max : Int32) : String
      return text[min...max] unless text.includes?('\n')
      map = [] of Int32
      text.each_char_with_index do |ch, i|
        map << i unless ch == '\n'
      end
      map << text.size
      lo = map[min]? || text.size
      hi = map[max]? || text.size
      text[lo, hi - lo]
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
  end
end
