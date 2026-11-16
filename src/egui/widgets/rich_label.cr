# RichLabel — a Label whose text carries inline markdown markup:
# `**bold**`, `*italic*`, `***both***`, `` `code` `` and
# `[label](url)` links, parsed by `RichText#styled_runs` into styled
# runs (real bold/italic variant faces, the monospace family for code) and
# laid out as one wrapping galley. Plain `Label` stays verbatim —
# markup parsing is THIS widget's job.
#
# Selectable like `Label` — through the document-wide selection
# (Context#text_selection): press places the caret, dragging selects
# across widgets, double-click selects a word, Ctrl+C copies. The
# selection indexes live in the FLATTENED row text — which is the
# markup-stripped text (exactly what the runs spell out), so copying
# yields clean prose without the markers. Links stay live: the cursor
# becomes a pointer over a link span, and a click opens it (a drag
# that turns into a selection does not).

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

    # Prebuilt inline content — runs + link spans in place of the
    # marker parse: callers that converted their markup to styled
    # nodes themselves (markdown's HTML path) hand the result over and
    # #ui lays it out verbatim. Everything downstream (code chips,
    # selection, link hit-testing, #link_handler) is unchanged.
    property preset : Tuple(Array(TextRun), Array(RichText::LinkSpan))?

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

    # Retained paint (see paint_cache.cr), the Label pattern: content by
    # value (fresh RichLabel objects each frame), the resolved effective
    # Style by identity (it merges the theme + per-element override +
    # inline layer, and drives run generation — sizes, colors, chips).
    # Selectable labels cache only in the inert state: pointer frames
    # run for real (link clicks fire on the RELEASE), the context menu
    # needs its popup rendered, and a non-collapsed GLOBAL selection
    # repaints its highlight through here. A LINKED label runs for real
    # while hovered: link clicks, the Pointer cursor and link_at
    # geometry need the live galley — a link-less label stays cached
    # under hover.
    def paint_cache_key(ui : Ui)
      id = cache_id(ui)
      ctx = ui.ctx
      if @userselect
        # Press/drag/release frames place the caret and fire link
        # clicks — all must run for real (the primary and secondary
        # buttons carry separate press state).
        return nil if ctx.input.pointer_pressed? ||
                      ctx.input.pointer_down? ||
                      ctx.input.pointer_released? ||
                      ctx.input.secondary_pressed? ||
                      ctx.input.secondary_down? ||
                      ctx.input.secondary_released?
        return nil if ctx.popup_open?("context_menu_#{id.value}")
        return nil if ctx.text_selection.any_selection?
      end
      state = ctx.memory.interaction_state(id)
      # Hover over a LINKED label runs for real: link clicks, the
      # Pointer cursor and link_at geometry need the live galley. The
      # link spans are parsed lazily by styled_runs (empty on a fresh
      # instance), so the gate scans the markup marker instead — a
      # false positive only costs the cache miss. A preset carries its
      # spans explicitly.
      preset_linked = @preset.try { |p| !p[1].empty? }
      return nil if state == "hover" &&
                    (preset_linked || @rich.text.includes?("]("))
      style = effective_style(ui, id)
      {"richlabel", @rich.text, @rich.size, @rich.color, @rich.bold?,
       @rich.italic?, @rich.underline?, @rich.strikethrough?,
       @wrap, @userselect, @line_height, @link_handler.nil?,
       ui.layout.vertical?, ui.available_width,
       ctx.mono_fonts.nil?, style.object_id,
       @style_override.try(&.hash),
       @preset.try { |p| p[0].hash }, @preset.try { |p| p[1].hash }}.hash
    end

    # #ui's non-paint side effects: the text cursor over hovered labels
    # and the cell's re-registration — a paint-cache replay must keep
    # the galley hit-testable for the global selection gesture.
    def cache_replay(ui : Ui, response : Response) : Nil
      return unless @userselect
      ui.ctx.set_cursor_icon(Egui::CursorIcon::Text) if response.hovered?
      # response.id, NOT cache_id(ui) — the replay minted this widget's
      # id span already, so peeking the next id would hand back the
      # SIBLING below (see Label#cache_replay).
      ui.ctx.text_selection.reregister(response.id, response.rect)
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
      if (preset = @preset)
        runs = preset[0]
        # A per-element font_size/weight override beats the preset's
        # own sizes/weights (the inspector's Element tab must visibly
        # work on markdown's preset labels, not be a silent no-op):
        # rebuild the affected runs, same rule as styled_runs'.
        if ov_size || !ov_bold.nil?
          runs = runs.map do |r|
            TextRun.new(r.text, ov_size || r.size, r.color, r.underline?,
              r.family, ov_bold.nil? ? r.bold? : ov_bold, r.italic?,
              r.strikethrough?, r.background)
          end
        end
        links = preset[1]
      else
        runs = @rich.styled_runs(style.font_size, visuals.text_color,
          visuals.hyperlink_color, ov_size, ov_bold)
        links = @rich.link_spans
      end
      # Inline code = monospace runs in a rounded chip; without a
      # mono stack they also retint weaker (the font alone can't
      # distinguish them).
      runs = RichLabel.apply_code_chips(runs, visuals.dark)
      runs = RichText.fade_code_runs(runs, visuals) if ui.ctx.mono_fonts.nil?

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

    # Highlight + link handling on the document-wide selection model:
    # the widget registers its galley as a cell (Context#text_selection)
    # and paints its slice; link clicks stay local (they need this
    # widget's spans).
    private def paint(ui : Ui, response : Response, id : Id, rect : Rect,
                      galley : Galley, runs : Array(TextRun),
                      links : Array(RichText::LinkSpan), fonts : Fonts,
                      style : Style, face_family : String?) : Nil
      ctx = ui.ctx
      visuals = style.visuals
      # Run stacks for caret/selection geometry — x_at measures each
      # run through ITS stack (inline code is mono), matching the draw.
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ctx.fonts_for(family, bold, italic) }

      flat = galley.rows.map(&.text).join

      over_link = response.hovered? && (pos = ctx.input.pointer_pos) &&
                  link_at(galley, rect, pos, fonts, resolve, links)
      ctx.set_cursor_icon(over_link ? CursorIcon::Pointer : CursorIcon::Text) if response.hovered?

      # Register as a selectable cell of the global selection. Copy
      # text = the flat text verbatim (markup-stripped — no '\n'
      # mapping, same as the old per-widget copy).
      ctx.text_selection.register(id, rect, rect, galley, fonts, resolve,
        nil, flat, flat, false)

      # A click (press+release without a drag) on a link span opens
      # it — a drag through a link still selects text (the gesture
      # lives in TextSelection). An app-set #link_handler intercepts
      # the raw target (markdown viewers navigate themselves).
      if response.clicked? && (pos = ctx.input.pointer_pos) &&
         (span = link_at(galley, rect, pos, fonts, resolve, links))
        if (handler = @link_handler)
          handler.call(span.url)
        else
          Hyperlink.open_url(span.url)
        end
      end

      # Mouse copy: right-click / long-press opens Copy / Select all
      # (the Label twin of TextEditMenu), acting on the GLOBAL
      # selection — a drag may span several cells.
      sel_text = ctx.text_selection.selected_text
      response.context_menu do |menu|
        menu.enabled(ctx.text_selection.any_selection?) do |m|
          m.menu_item("Copy", nil, :copy, "Ctrl+C") do
            Egui::SystemPorts::Clipboard.text = sel_text
          end
        end
        menu.enabled(!flat.empty?) do |m|
          m.menu_item("Select all", nil, nil, "Ctrl+A") do
            ctx.text_selection.select_cell(id, flat)
          end
        end
      end

      # Selection strips per row (index, x0, x1) — this cell's slice of
      # the global selection, painted by paint_galley BETWEEN the chips
      # and the glyphs, so a selected inline-code chip shows the
      # highlight, not the chip over it.
      segs = nil
      if (range = ctx.text_selection.range_for(id))
        sel_min, sel_max = range
        row_starts = row_char_starts(galley)
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
        segs = nil if segs.empty?
      end

      ui.painter.paint_galley(rect.min, galley, fonts, visuals.text_color,
        face_family, resolve, segs, visuals.text_selection)
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
      # Nearest boundary, half-glyph snapping (TextSelection#caret_at —
      # the browser caret rule; see the note there).
      prev = 0.0
      best = text.size
      (1..text.size).each do |i|
        x = galley.x_at(row_index, i, fonts, resolve)
        if x >= local_x
          best = (x - local_x) <= (local_x - prev) ? i : i - 1
          break
        end
        prev = x
      end
      row_starts[row_index] + best
    end
  end
end
