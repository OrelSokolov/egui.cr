# RichLabel — a Label whose text carries inline markdown markup:
# `**bold**`, `*italic*`, `***both***`, `` `code` `` and
# `[label](url)` links, parsed by `RichText#styled_runs` into styled
# runs (real bold/italic variant faces, the monospace family for code) and
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
    # (GitHub's light tint and its dark counterpart), painted by
    # `paint_galley` from the run's `background`.
    INLINE_CODE_BG      = Color32.rgba(0xE9, 0xED, 0xF0, 255)
    INLINE_CODE_BG_DARK = Color32.rgba(0x29, 0x30, 0x38, 255)

    # Mark monospace runs as inline-code chips (the backgrounded runs
    # `paint_galley` draws). Shared with the measurement side of
    # TableTextRenderer: its reserved heights must match what THIS
    # widget lays out, backgrounds included — a chip's layout-reserved
    # side margins change where cells wrap.
    def self.apply_code_chips(runs : Array(TextRun),
                              dark : Bool = false) : Array(TextRun)
      chip = dark ? INLINE_CODE_BG_DARK : INLINE_CODE_BG
      runs.map do |r|
        if r.family == "monospace"
          TextRun.new(r.text, r.size, r.color, r.underline?, r.family,
            r.bold?, r.italic?, r.strikethrough?, chip)
        else
          r
        end
      end
    end

    getter rich : RichText
    getter wrap : Bool?
    getter? userselect : Bool
    # Link click interceptor: when set, it receives the raw target
    # (markdown viewers navigate themselves); nil opens through the
    # OS (`Hyperlink.open_url`).
    property link_handler : (String ->)?

    # Line-height multiplier for the galley (nil = Fonts::LINE_H_FACTOR);
    # markdown body text passes 1.5 (GitHub-like) so the inline-code
    # chip fits inside the line box.
    property line_height : Float64?

    def initialize(text : String, size : Float64? = nil,
                   wrap : Bool? = nil, userselect : Bool = true,
                   id : String? = nil, line_height : Float64? = nil)
      @rich = RichText.new(text)
      @rich.size(size) if size
      @wrap = wrap
      @userselect = userselect
      @id_name = id
      @line_height = line_height
    end

    def initialize(@rich : RichText, wrap : Bool? = nil,
                   userselect : Bool = true, id : String? = nil,
                   line_height : Float64? = nil)
      @wrap = wrap
      @userselect = userselect
      @id_name = id
      @line_height = line_height
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
      # A per-element font_size override (inspector Element tab) beats
      # the RichText's own explicit .size — same rule as `Label`: the
      # edit must visibly work on sized labels (markdown headings),
      # not be a silent no-op. No class layer here (no style_class).
      # font_weight follows the same element layer and resolves
      # through the REAL weight axis (a cut face when the family has
      # one, else the bold flag).
      ov = ui.ctx.id_style_state_vars(id, nil)
      ov_size = ov.try(&.f64?("font_size")).try { |s| {s, 0.0}.max }
      weight = ov.try(&.f64?("font_weight"))
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, weight, @rich.bold?)
      ov_bold = weight.nil? ? nil : face_bold
      runs = @rich.styled_runs(style.font_size, visuals.text_color,
        visuals.hyperlink_color, ov_size, ov_bold)
      # Inline code = monospace runs in a rounded chip; without a
      # mono stack they also retint weaker (the font alone can't
      # distinguish them).
      runs = RichLabel.apply_code_chips(runs, visuals.dark)
      runs = RichText.fade_code_runs(runs, visuals) if ui.ctx.mono_fonts.nil?
      links = @rich.link_spans

      wrap = @wrap.nil? ? ui.layout.vertical? : @wrap
      available = ui.available_width
      max_width = wrap && available > 0.0 ? available : nil
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ui.ctx.fonts_for(family, bold, italic) }
      galley = fonts.layout(runs, max_width, resolve, @line_height)

      rect = ui.allocate_at_least(galley.size)
      response = ui.interact(rect, id,
        @userselect ? Sense.click_and_drag : Sense.none)

      if @userselect
        paint(ui, response, id, rect, galley, runs, links, fonts, style,
          face_family)
      else
        ui.painter.paint_galley(rect.min, galley, fonts,
          visuals.text_color, face_family, resolve)
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
                      style : Style, face_family : String?) : Nil
      ctx = ui.ctx
      visuals = style.visuals
      # Run stacks for caret/selection geometry — x_at measures each
      # run through ITS stack (inline code is mono), matching the draw.
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ctx.fonts_for(family, bold, italic) }
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
                  link_at(galley, rect, pos, fonts, resolve, links)
      ctx.set_cursor_icon(over_link ? CursorIcon::Pointer : CursorIcon::Text) if response.hovered?

      menu_id = "context_menu_#{id.value}"
      menu_open = ctx.popup_open?(menu_id)
      # A press anywhere else ends the selection — except while this
      # label's own context menu is open (the press ON a menu row must
      # not kill the selection Copy acts on).
      if ctx.input.pointer_pressed? && !response.hovered? && !menu_open
        anchor = -1
      elsif anchor >= 0 && anchor != cursor && ctx.memory.focus.id.nil? &&
            ctx.input.consume_key(KeyCode::Escape)
        anchor = -1
      end

      if (response.pressed? || response.clicked?) &&
         (pos = ctx.input.pointer_pos)
        if response.double_clicked?
          cursor, anchor = word_range(flat,
            caret_at(galley, row_starts, rect, pos, fonts, resolve))
        else
          cursor = anchor = caret_at(galley, row_starts, rect, pos, fonts, resolve)
        end
      end
      if response.drag_started? && (pos = ctx.input.pointer_pos) && anchor == -1
        anchor = caret_at(galley, row_starts, rect, pos, fonts, resolve)
      end
      if response.dragged? && (pos = ctx.input.pointer_pos)
        cursor = caret_at(galley, row_starts, rect, pos, fonts, resolve)
      end

      # Ctrl/Cmd+C copies the selection (upstream
      # `Modifiers::command`) — only while no widget holds keyboard
      # focus (a focused TextEdit owns the clipboard).
      if anchor >= 0 && anchor != cursor && ctx.memory.focus.id.nil? &&
         ctx.input.modifiers.command? && ctx.input.consume_key(KeyCode::C)
        sel_min = {cursor, anchor}.min
        sel_max = {cursor, anchor}.max
        Egui::SystemPorts::Clipboard.text = flat[sel_min, sel_max - sel_min]
      end

      # Mouse copy: right-click / long-press opens Copy / Select all
      # (the Label twin of TextEditMenu). Handlers run during the popup
      # render — inside this method, before the state is stored, so
      # Select all can move the cursor/anchor it mutates.
      has_sel = anchor >= 0 && anchor != cursor
      sel_lo = {cursor, anchor}.min
      sel_hi = {cursor, anchor}.max
      sel_text = has_sel ? flat[sel_lo, sel_hi - sel_lo] : ""
      response.context_menu do |menu|
        menu.enabled(has_sel) do |m|
          m.menu_item("Copy", nil, :copy, "Ctrl+C") do
            Egui::SystemPorts::Clipboard.text = sel_text
          end
        end
        menu.enabled(!flat.empty?) do |m|
          m.menu_item("Select all", nil, nil, "Ctrl+A") do
            cursor = flat.size
            anchor = 0
          end
        end
      end

      # A click (press+release without a drag) on a link span opens
      # it — after selection math, so a drag through a link still
      # selects text. An app-set #link_handler intercepts the raw
      # target (markdown viewers navigate themselves).
      if response.clicked? && (pos = ctx.input.pointer_pos) &&
         (span = link_at(galley, rect, pos, fonts, resolve, links))
        if (handler = @link_handler)
          handler.call(span.url)
        else
          Hyperlink.open_url(span.url)
        end
      end

      ctx.memory.data.set_int(id, cursor)
      ctx.memory.data.set_int(anchor_id, anchor)

      # Selection strips per row (index, x0, x1) — painted by
      # paint_galley BETWEEN the chips and the glyphs, so a selected
      # inline-code chip shows the highlight, not the chip over it.
      sel = nil
      if anchor >= 0 && anchor != cursor && !flat.empty?
        sel_min = {cursor, anchor}.min
        sel_max = {cursor, anchor}.max
        segs = [] of Tuple(Int32, Float64, Float64)
        galley.rows.each_with_index do |row, i|
          row_start = row_starts[i]
          lo = {sel_min, row_start}.max
          hi = {sel_max, row_start + row.text.size}.min
          if lo < hi
            segs << {i, galley.x_at(i, lo - row_start, fonts, resolve),
                     galley.x_at(i, hi - row_start, fonts, resolve)}
          end
        end
        sel = segs unless segs.empty?
      end

      ui.painter.paint_galley(rect.min, galley, fonts, visuals.text_color,
        face_family, resolve, sel, visuals.selection_fill)
    end

    # The link span under `pos`, if any: char index in the flattened
    # row text first (same geometry as the caret), then a range check
    # against the spans. Wrap-broken rows keep every source char, so
    # the flattened text matches the spans' offsets.
    private def link_at(galley : Galley, rect : Rect, pos : Pos2,
                        fonts : Fonts,
                        resolve : (String?, Bool, Bool) -> Fonts,
                        links : Array(RichText::LinkSpan))
      return nil if galley.rows.empty? || links.empty?
      return nil unless pos.x >= rect.left && pos.x <= rect.right &&
                       pos.y >= rect.top && pos.y <= rect.bottom
      index = caret_at(galley, row_char_starts(galley), rect, pos, fonts, resolve)
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
                         rect : Rect, pos : Pos2, fonts : Fonts,
                         resolve : (String?, Bool, Bool) -> Fonts) : Int32
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
        break if galley.x_at(row_index, i, fonts, resolve) >= local_x
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
