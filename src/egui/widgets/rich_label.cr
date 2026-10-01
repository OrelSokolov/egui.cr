# RichLabel — a Label whose text carries inline markdown markup:
# `**bold**`, `*italic*`, `***both***`, `` `code` `` and
# `[label](url)` links, parsed by `RichText#styled_runs` into styled
# runs (synthetic bold/italic, the monospace family for code) and
# laid out as one wrapping galley. Plain `Label` stays verbatim —
# markup parsing is THIS widget's job.
#
# Selectable like `Label`: press places the caret, dragging selects a
# range, double-click selects a word, Ctrl+C copies. The selection
# lives in the FLATTENED row text — which is the markup-stripped
# text (exactly what the runs spell out), so copying yields clean
# prose without the markers. Links stay live: the cursor becomes a
# pointer over a link span, and a click opens it (a drag that turns
# into a selection does not).

module Egui
  class RichLabel
    include Widget

    # Inline-code chip: a soft gray rounded rect behind `code` spans
    # (GitHub-light tint), painted by `paint_galley` from the run's
    # `background`.
    INLINE_CODE_BG = Color32.rgba(0xE9, 0xED, 0xF0, 255)

    getter rich : RichText
    getter wrap : Bool?
    getter? userselect : Bool
    # Link click interceptor: when set, it receives the raw target
    # (markdown viewers navigate themselves); nil opens through the
    # OS (`Hyperlink.open_url`).
    property link_handler : (String ->)?

    def initialize(text : String, size : Float64? = nil,
                   wrap : Bool? = nil, userselect : Bool = true,
                   id : String? = nil)
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
      visuals = style.visuals
      runs = @rich.styled_runs(style.font_size, visuals.text_color,
        visuals.hyperlink_color)
      # Inline code = monospace runs in a rounded chip; without a
      # mono stack they also retint weaker (the font alone can't
      # distinguish them).
      runs = runs.map do |r|
        if r.family == "monospace"
          TextRun.new(r.text, r.size, r.color, r.underline?, r.family,
            r.bold?, r.italic?, r.strikethrough?, INLINE_CODE_BG)
        else
          r
        end
      end
      runs = RichText.fade_code_runs(runs, visuals) if ui.ctx.mono_fonts.nil?
      links = @rich.link_spans

      wrap = @wrap.nil? ? ui.layout.vertical? : @wrap
      available = ui.available_width
      max_width = wrap && available > 0.0 ? available : nil
      fonts = ui.ctx.fonts_for(style.font_family)
      resolve = ->(family : String?) { ui.ctx.fonts_for(family) }
      galley = fonts.layout(runs, max_width, resolve)

      rect = ui.allocate_at_least(galley.size)
      response = ui.interact(rect, id,
        @userselect ? Sense.click_and_drag : Sense.none)

      if @userselect
        paint(ui, response, id, rect, galley, runs, links, fonts, style)
      else
        ui.painter.paint_galley(rect.min, galley, fonts,
          visuals.text_color, style.font_family, resolve)
      end
      response
    end

    # Selection + link handling — the Label selection mechanics on a
    # multi-run galley. Byte indexes live in the flattened row text
    # (== the markup-stripped source); the anchor cell mirrors
    # Label's 0x5EED child id.
    private def paint(ui : Ui, response : Response, id : Id, rect : Rect,
                      galley : Galley, runs : Array(TextRun),
                      links : Array(RichText::LinkSpan), fonts : Fonts,
                      style : Style) : Nil
      ctx = ui.ctx
      visuals = style.visuals
      resolve = ->(family : String?) { ctx.fonts_for(family) }
      anchor_id = id.child(0x5EED_u64)
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

      over_link = response.hovered? && (pos = ctx.input.pointer_pos) &&
                  link_at(galley, rect, pos, fonts, links)
      ctx.set_cursor_icon(over_link ? CursorIcon::Pointer : CursorIcon::Text) if response.hovered?

      if ctx.input.pointer_pressed? && !response.hovered?
        anchor = -1
      elsif anchor >= 0 && anchor != cursor && ctx.memory.focus.id.nil? &&
            ctx.input.consume_key(KeyCode::Escape)
        anchor = -1
      end

      if (response.pressed? || response.clicked?) &&
         (pos = ctx.input.pointer_pos)
        if response.double_clicked?
          cursor, anchor = word_range(flat,
            caret_at(galley, row_starts, rect, pos, fonts))
        else
          cursor = anchor = caret_at(galley, row_starts, rect, pos, fonts)
        end
      end
      if response.drag_started? && (pos = ctx.input.pointer_pos) && anchor == -1
        anchor = caret_at(galley, row_starts, rect, pos, fonts)
      end
      if response.dragged? && (pos = ctx.input.pointer_pos)
        cursor = caret_at(galley, row_starts, rect, pos, fonts)
      end

      # Ctrl+C copies the selection — only while no widget holds
      # keyboard focus (a focused TextEdit owns the clipboard).
      if anchor >= 0 && anchor != cursor && ctx.memory.focus.id.nil? &&
         ctx.input.modifiers.ctrl && ctx.input.consume_key(KeyCode::C)
        sel_min = {cursor, anchor}.min
        sel_max = {cursor, anchor}.max
        Egui::SystemPorts::Clipboard.text = flat[sel_min, sel_max - sel_min]
      end

      # A click (press+release without a drag) on a link span opens
      # it — after selection math, so a drag through a link still
      # selects text. An app-set #link_handler intercepts the raw
      # target (markdown viewers navigate themselves).
      if response.clicked? && (pos = ctx.input.pointer_pos) &&
         (span = link_at(galley, rect, pos, fonts, links))
        if (handler = @link_handler)
          handler.call(span.url)
        else
          Hyperlink.open_url(span.url)
        end
      end

      ctx.memory.data.set_int(id, cursor)
      ctx.memory.data.set_int(anchor_id, anchor)

      # Selection highlights per row, behind the text.
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
        style.font_family, resolve)
    end

    # The link span under `pos`, if any: char index in the flattened
    # row text first (same geometry as the caret), then a range check
    # against the spans. Wrap-broken rows keep every source char, so
    # the flattened text matches the spans' offsets.
    private def link_at(galley : Galley, rect : Rect, pos : Pos2,
                        fonts : Fonts, links : Array(RichText::LinkSpan))
      return nil if galley.rows.empty? || links.empty?
      return nil unless pos.x >= rect.left && pos.x <= rect.right &&
                       pos.y >= rect.top && pos.y <= rect.bottom
      index = caret_at(galley, row_char_starts(galley), rect, pos, fonts)
      links.find { |l| index >= l.from && index < l.to }
    end

    private def row_char_starts(galley : Galley) : Array(Int32)
      starts = [] of Int32
      start = 0
      galley.rows.each do |row|
        starts << start
        start += row.text.size
      end
      starts
    end

    # Char index of the pointer inside the flattened row text: the row
    # under the pointer (y), then the nearest x boundary within it —
    # Label's caret geometry, verbatim. Char units, matching the
    # spans (multibyte glyphs count as one).
    private def caret_at(galley : Galley, row_starts : Array(Int32),
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

    # Word around `pos` for double-click selection — Label's
    # word_range, verbatim (ASCII letters/digits group together).
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
