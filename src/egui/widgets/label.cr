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
#
# CSS-wise the label styles under the "label" class and reads the
# box-model `padding` (per-side `padding.top/…` or the scalar shorthand):
# padding grows the allocated rect and offsets the text into the
# content box, and a wrapping label wraps against the width minus the
# horizontal padding.

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

    # Text-decoration chainables (the `Hyperlink#underline` parity):
    # a line under / through the WHOLE label's text.
    def underline : Label
      @rich.underline
      self
    end

    def strikethrough : Label
      @rich.strikethrough
      self
    end

    def style_class : String?
      "label"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + [StyleProp.new("padding", :box)]
    end

    def inspector_label : String?
      @rich.text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id, "label")
      style = effective_style(ui, id, class_vars)
      # CSS `padding` box (per-side, default 0 — an unpadded label keeps
      # its exact upstream sizing).
      pad = class_vars.box?("padding") || StyleBox.new
      # A font_size that arrived through the cascade (a "label" class
      # rule or the inspector's per-element override — both live in
      # `class_vars`) beats the RichText's own explicit .size; without
      # one the RichText size keeps winning (upstream behavior). The
      # override matters on sized labels (headings, `.size(...)`),
      # where the inspector edit used to be a silent no-op.
      run_size = class_vars.f64?("font_size").try { |s| {s, 0.0}.max }
      # font_weight rides the same cascade: a set value beats the
      # RichText's own .bold. Resolution goes through the REAL weight
      # axis — a family with cut files (Noto Sans Thin…Black) draws
      # through the actual face; without one it degrades to the bold
      # flag (the primary's variant faces), never an emulation.
      weight = class_vars.f64?("font_weight")
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, weight, @rich.bold?)
      run_bold = weight.nil? ? nil : face_bold
      runs = @rich.runs(style.font_size, style.visuals.text_color,
        run_size, run_bold)
      # Code blocks share the inline-code fallback: without a mono
      # stack they draw in the proportional font — retint them.
      runs = RichText.fade_code_runs(runs, style.visuals) if ui.ctx.mono_fonts.nil?
      # Default (nil): wrap only where the label owns the rest of the
      # line — a vertical layout (upstream `TextWrapMode::Wrap`); a
      # label inside a horizontal row stays inline (`Extend`). A zero
      # remaining width would char-break every glyph onto its own row —
      # treat it as unbounded instead.
      wrap = @wrap.nil? ? ui.layout.vertical? : @wrap
      available = ui.available_width
      room = available - pad.horizontal
      max_width = wrap && room > 0.0 ? room : nil
      # Runs may carry their own family (RichText#code — code blocks):
      # resolve those through ctx.fonts_for for BOTH measuring and
      # drawing; the base runs measure through the weight-resolved
      # stack (`fonts` above — a real cut face when one matched).
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ui.ctx.fonts_for(family, bold, italic) }
      galley = fonts.layout(runs, max_width, resolve)

      rect = ui.allocate_at_least(
        galley.size + Vec2.new(pad.horizontal, pad.vertical))
      response = ui.interact(rect, id,
        @userselect ? Sense.click_and_drag : Sense.none)

      # The text lives in the content box (rect minus padding).
      content = Rect.from_min_size(
        rect.min + Vec2.new(pad.left, pad.top), galley.size)
      if @userselect
        paint_selectable(ui, response, id, content, galley, fonts,
          face_family, style)
      else
        ui.painter.paint_galley(content.min, galley, fonts,
          style.visuals.text_color, face_family, resolve)
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
                                 fonts : Fonts, face_family : String?,
                                 style : Style) : Nil
      ctx = ui.ctx
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
      ui.painter.paint_galley(rect.min, galley, fonts, visuals.text_color,
        face_family, ->(family : String?, bold : Bool, italic : Bool) { ctx.fonts_for(family, bold, italic) })
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
