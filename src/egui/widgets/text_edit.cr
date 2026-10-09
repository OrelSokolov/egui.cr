# Port of egui_upstream/crates/egui/src/widgets/text_edit/ (stage 2:
# single-line WITH selection and clipboard; multi-line and IME follow
# later).
#
# Max-width mode `scroll`: the field never grows past the remaining
# width of its region (the Ui max-size rule bounds the rect); the
# text scrolls horizontally inside the fixed box instead, the offset
# stored per-id and auto-following the caret so typing at either end
# always keeps the caret (and thus the edit point) in view.
#
# Cursor position and selection anchor are system state (Int32
# CHARACTER indexes under the widget id; anchor -1 = no selection) —
# they survive
# IdTypeMap pruning like every widget cell. While focused: text edits
# at the cursor (replacing the selection when one exists), Backspace/
# Delete edit around it, Left/Right/Home/End move it (Shift extends the
# selection, Ctrl+A selects everything), Ctrl+C/X/V go through the
# Clipboard system port, Escape drops focus. Clicking places the cursor
# via Galley#x_at, double-clicking selects a word, dragging selects a
# range. The new buffer flows out through Response#widget_text.
#
# Password mode (`password: true`): the galley is laid out on a masked
# copy of the text — one BLACK CIRCLE per character — so the field
# shows circles instead of what was typed. Cursor, selection, edits
# and clipboard keep operating on the real text. The masked galley
# has exactly one circle per character, so display geometry and edit
# state share the same CHARACTER-COUNT space (Crystal String#[]/.size
# count characters, not bytes) — no byte↔char translation, only a
# clamp against the text length for stray indexes (a stale cell, a
# click mapped onto the longer hint galley).

module Egui
  class TextEdit
    include Widget

    # U+25CF BLACK CIRCLE — present in every candidate UI font
    # (DejaVu, Ubuntu, Roboto, Liberation, Segoe UI, Arial, SFNS).
    MASK_CHAR = "●"

    def initialize(@text : String, @hint : String? = nil,
                   @password : Bool = false, @focus_id : String? = nil,
                   @frame : Bool = true,
                   @cursor_style : Symbol = :line,
                   @cursor_blinks : Bool = true)
    end

    def ui(ui : Ui) : Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts_for(style.font_family)
      id = @focus_id ? ui.named_id(@focus_id.not_nil!) : ui.next_widget_id
      anchor_id = id.child(0x5EED_u64)
      scroll_id = id.child(0x5C20_u64)
      # The anchor cell has no #interact of its own — mark it used or
      # end-frame pruning drops the selection every frame.
      ui.ctx.memory.use_id(anchor_id)
      ui.ctx.memory.use_id(scroll_id)

      cursor = ui.ctx.memory.data.get_int(id, @text.size).clamp(0, @text.size)
      # A stale anchor cell (the buffer shrank since the selection was
      # made — an app replaced it, a combo cleared its filter) must not
      # survive past the current length: sel_max would index past the
      # string and crash the first edit.
      anchor = ui.ctx.memory.data.get_int(anchor_id, -1)
      anchor = {anchor, @text.size}.min if anchor > @text.size
      new_text = @text
      changed = false

      # Keyboard BEFORE layout: an edit made this frame must size the
      # field this frame. Sizing from a pre-edit galley leaves the rect
      # one frame behind the text, and the caret auto-follow then scrolls
      # against that stale view — while typing at the end the field keeps
      # growing yet the text slides left (and snaps back once typing
      # pauses), which reads as the field jittering. Focus is read
      # straight from memory so the edit lands before the galley exists
      # (a focusing click types from the next frame on).
      if ui.ctx.memory.focus.has_focus?(id)
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        new_text, cursor, anchor, changed =
          handle_keyboard(ui.ctx, @text, cursor, anchor)
        ui.ctx.request_repaint if @cursor_blinks # caret blink
      end

      # Password mode replaces every character with MASK_CHAR for
      # display; the masked galley has exactly one circle per
      # character, so display geometry and edit state share the same
      # CHARACTER-COUNT space (see the header comment). The lambdas
      # clamp stray indexes so they never reach the string slices as
      # out-of-bounds.
      display = new_text
      display = String.build { |b| new_text.each_char { b << MASK_CHAR } } if @password
      n_chars = new_text.size
      # Edit-state index → galley index, and cursor_at result →
      # edit-state index: identity, bounded to the text length.
      d_idx = ->(i : Int32) { i.clamp(0, n_chars) }
      r_idx = d_idx

      shown = new_text.empty? && (hint = @hint) ? hint : display
      galley = fonts.layout([TextRun.new(shown, font_size)])

      pad = style.spacing.button_padding
      # The border stroke is drawn INSIDE the rect (backend inset), so
      # the layout reserves it on every side: text, selection and caret
      # start past it (upstream expands the frame inner_margin the same
      # way). Reserved at the focused width so focusing doesn't jitter.
      border = 2.0
      inset = Vec2.new(pad.x + border, pad.y + border)
      # An empty field with no hint lays out to a zero-height galley
      # (no rows) — fall back to the line height, the same one the
      # caret uses, so the field keeps its height before the first
      # character gives the galley a real row.
      line_h = {galley.size.y, font_size * Fonts::LINE_H_FACTOR}.max
      # Max-width mode `scroll`: natural width clamped to what the
      # region has left — the field never grows past its parent's
      # right edge, long text scrolls inside instead.
      natural_w = {galley.size.x, style.spacing.interact_size.x}.max +
                  inset.x * 2.0
      size = Vec2.new({natural_w, ui.available_width}.min,
        {line_h, style.spacing.interact_size.y}.max + inset.y * 2.0)
      rect = ui.allocate_at_least(size)
      view_w = {rect.width - inset.x * 2.0, 0.0}.max
      scroll = ui.ctx.memory.data.get_f64(scroll_id, 0.0)
      response = ui.interact(rect, id,
        Sense::Click | Sense::Drag | Sense::Focusable)
      # Upstream: text caret cursor over the edit field.
      ui.ctx.set_cursor_icon(CursorIcon::Text) if response.hovered?

      # Press places the caret immediately (real input); a synthetic
      # same-frame press+release arrives classified as a click and does
      # the same on release. Double-click selects a word.
      if response.pressed? || response.clicked?
        response.request_focus
        if (pos = ui.ctx.input.pointer_pos)
          if response.double_clicked?
            cursor, anchor = word_range(new_text,
              r_idx.call(cursor_at(fonts, galley, rect, inset, scroll, pos.x)))
          else
            cursor = r_idx.call(cursor_at(fonts, galley, rect, inset, scroll, pos.x))
            anchor = cursor
          end
        end
      end
      # Drag-select: the anchor stays where the press put it, the caret
      # follows the pointer (a drag with no prior press anchors here).
      if response.drag_started? && (pos = ui.ctx.input.pointer_pos) && anchor == -1
        anchor = r_idx.call(cursor_at(fonts, galley, rect, inset, scroll, pos.x))
      end
      if response.dragged? && (pos = ui.ctx.input.pointer_pos)
        cursor = r_idx.call(cursor_at(fonts, galley, rect, inset, scroll, pos.x))
      end

      ui.ctx.memory.data.set_int(id, cursor)
      ui.ctx.memory.data.set_int(anchor_id, anchor)

      # Caret auto-follow: while focused, shift the horizontal scroll
      # so the caret stays inside the view (typing at either end,
      # Home/End, clicks past the visible edge). Re-clamped against
      # the content so shrinking text pulls the offset back.
      max_scroll = {galley.size.x - view_w, 0.0}.max
      scroll = scroll.clamp(0.0, max_scroll)
      if response.has_focus?
        caret_x = galley.x_at(0, d_idx.call(cursor), fonts)
        if caret_x < scroll
          scroll = caret_x
        elsif caret_x + 1.0 > scroll + view_w
          scroll = caret_x + 1.0 - view_w
        end
        scroll = scroll.clamp(0.0, max_scroll)
      end
      ui.ctx.memory.data.set_f64(scroll_id, scroll)

      visuals = style.visuals
      bg = response.has_focus? ? visuals.button_active : visuals.button_weak
      # Upstream: the focused field paints its own border in the
      # selection stroke color (upstream `visuals.selection.stroke`),
      # not a ring outside the frame — an outside ring both escapes the
      # widget bounds and gets scissored by the parent clip.
      # `frame: false` (an embedded field — SelectBox's search entry):
      # the host owns the frame, the edit draws content only.
      if @frame
        stroke_color = response.has_focus? ? visuals.selection_fill : visuals.button_stroke
        stroke_w = response.has_focus? ? border : 1.0
        ui.painter.rect(rect, 4.0, bg, stroke_color, stroke_w)
      end

      inner = rect.min + inset
      color = if new_text.empty? && @hint
                visuals.fade_color(visuals.text_color, 0.55)
              else
                visuals.text_color
              end

      # Content (selection, text, caret) is painted shifted by the
      # horizontal scroll and clipped to the field's INNER rect (inside
      # the border + padding) — a scrolled row must cut at the content
      # edge, never paint over the padding/border zone (a wide mask
      # glyph bleeding into the border reads as misaligned).
      outer_clip = ui.painter.clip
      content_clip = Rect.new(
        Pos2.new({outer_clip.min.x, rect.min.x + inset.x}.max,
          {outer_clip.min.y, rect.min.y + inset.y}.max),
        Pos2.new({outer_clip.max.x, rect.max.x - inset.x}.min,
          {outer_clip.max.y, rect.max.y - inset.y}.min))
      ui.painter.clip = content_clip

      # Selection highlight behind the text (the galley is laid out on
      # the actual text, never the hint).
      sel_min = {cursor, anchor}.min
      sel_max = {cursor, anchor}.max
      if anchor >= 0 && anchor != cursor && !new_text.empty?
        x0 = galley.x_at(0, d_idx.call(sel_min), fonts)
        x1 = galley.x_at(0, d_idx.call(sel_max), fonts)
        top = inner.y + 1.0
        height = {galley.size.y - 2.0, 2.0}.max
        ui.painter.rect(
          Rect.from_min_size(Pos2.new(inner.x + x0 - scroll, top),
            Vec2.new(x1 - x0, height)),
          0.0, visuals.selection_fill)
      end

      ui.painter.paint_galley(
        Pos2.new(inner.x - scroll, inner.y), galley, fonts, color,
        style.font_family)

      ui.painter.clip = outer_clip

      # Caret while focused — a 1px line by default, or a vim-style
      # BLOCK with `cursor_style: :block`; it BLINKS (1s period) unless
      # `cursor_blinks: false` holds it steady (a steady caret needs no
      # repaints of its own). Painted AFTER the content clip is
      # restored: auto-follow can
      # park it exactly on the inner edge, where the half-pixel of its
      # centered stroke would otherwise be scissored away. The block
      # fills the cell of the character under the caret and re-draws
      # that character in the field's background color (inverse
      # video); past the last character it falls back to a space-width
      # cell. The glyph repaint goes through the CONTENT clip (like
      # the galley itself) so a caret parked at the edge cuts its
      # glyph at the same line.
      if response.has_focus? &&
         (@cursor_blinks ? (ui.ctx.input.time % 1.0) < 0.6 : true)
        if @cursor_style == :block
          col = d_idx.call(cursor)
          caret_x = galley.x_at(0, col, fonts)
          w = galley.x_at(0, col + 1, fonts) - caret_x
          w = {fonts.measure(" ", font_size).x, font_size * 0.5}.max if w <= 0.0
          ui.painter.rect(
            Rect.from_min_size(Pos2.new(inner.x + caret_x - scroll, inner.y + 1.0),
              Vec2.new(w, line_h - 2.0)), 0.0, visuals.text_color)
          if (ch = display[col]?)
            glyph_bg = @frame ? bg : visuals.window_fill
            row_h = galley.rows[0]?.try(&.height) || line_h
            ui.painter.clip = content_clip
            ui.painter.text(
              Pos2.new(inner.x + caret_x - scroll, inner.y + row_h / 2.0),
              ch.to_s, font_size, glyph_bg, family: style.font_family)
            ui.painter.clip = outer_clip
          end
        else
          caret_x = inner.x + galley.x_at(0, d_idx.call(cursor), fonts) - scroll
          top = inner.y + 1.0
          bottom = inner.y + line_h - 1.0
          ui.painter.line(Pos2.new(caret_x, top), Pos2.new(caret_x, bottom),
            1.0, visuals.text_color)
        end
      end

      response.widget_text = new_text
      response.mark_changed if changed
      response
    end

    # Maps a pointer x to a caret index — the CHARACTER count into the
    # row (the state keeps character indexes too; password mode's
    # masked galley has one circle per character, so the count maps
    # straight through). `scroll` shifts the text origin left, so the
    # probe compares against the VISIBLE text position, not the
    # layout origin.
    private def cursor_at(fonts : Fonts, galley : Galley, rect : Rect,
                          pad : Vec2, scroll : Float64,
                          pointer_x : Float64) : Int32
      row = galley.rows[0]?
      text = row.try(&.text) || ""
      origin = rect.left + pad.x - scroll
      return text.size if pointer_x >= origin + galley.size.x

      best = 0
      text.each_char_with_index do |_, i|
        x = galley.x_at(0, i, fonts)
        best = i
        break if origin + x >= pointer_x
      end
      best
    end

    # Word around `pos` for double-click selection: ASCII letters and
    # digits group together (character indexes, like the rest of the
    # widget).
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
      elsif !input.text.empty? && !input.shortcut_modifiers_down?
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
