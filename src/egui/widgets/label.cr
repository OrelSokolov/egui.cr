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
# `interaction.selectable_labels`): the label registers its galley as a
# cell of the DOCUMENT-WIDE text selection (see TextSelection — the
# browser model). Press places the caret, dragging selects across
# widgets, double-click selects a word, triple-click the whole label,
# Shift+click extends, Ctrl/Cmd+C copies the selection, Ctrl/Cmd+A
# selects all and a secondary press (right click) or long-press opens a
# Copy / Select all context menu. `userselect: false` reverts to the
# inert paint-only label (upstream `Sense::hover()`).
#
# CSS-wise the label styles under the "label" class and reads the
# box-model `padding` (per-side `padding.top/…` or the scalar shorthand):
# padding grows the allocated rect and offsets the text into the
# content box, and a wrapping label wraps against the width minus the
# horizontal padding. `text_align` ("left"/"center"/"right") places
# the galley inside the rect; the `align:` parameter does the same
# per widget.

module Egui
  class Label
    include Widget

    getter rich : RichText
    getter wrap : Bool?
    getter? userselect : Bool
    # Line-height multiplier for the galley (nil = Fonts::LINE_H_FACTOR).
    # Paragraph-style labels (markdown body) pass a roomier factor so
    # decorated runs (the inline-code chip) fit inside the line box.
    property line_height : Float64?
    # Preset layout runs (markdown syntax highlighting: one TextRun per
    # token). When set they replace `rich.runs` verbatim — the RichText
    # only carries the plain text (selection/measure fallback).
    getter preset_runs : Array(TextRun)?
    # Horizontal placement of the text inside the allocated rect:
    # nil/:left hugs the content box's left edge (upstream default),
    # :center/:right shift the galley by the free slack. Also stylable
    # as the CSS-like `text_align` key ("left" / "center" / "right")
    # — the explicit parameter wins.
    property align : Symbol?
    # Vertical offset of the galley inside the allocated rect
    # (positive = down) — the sub/sup baseline shift: the label keeps
    # its flow-driven rect (a full line height) and the TEXT moves
    # within it, so a horizontal row still centers it like any
    # sibling label while the glyphs sit below/above the line's
    # baseline.
    property baseline_shift : Float64 = 0.0

    def initialize(text : String, size : Float64? = nil, wrap : Bool? = nil,
                   userselect : Bool = true, id : String? = nil,
                   line_height : Float64? = nil, align : Symbol? = nil)
      @rich = RichText.new(text)
      @rich.size(size) if size
      @wrap = wrap
      @userselect = userselect
      @id_name = id
      @line_height = line_height
      @preset_runs = nil
      @align = align
    end

    def initialize(@rich : RichText, wrap : Bool? = nil,
                   userselect : Bool = true, id : String? = nil,
                   @preset_runs : Array(TextRun)? = nil,
                   line_height : Float64? = nil, align : Symbol? = nil)
      @wrap = wrap
      @userselect = userselect
      @id_name = id
      @line_height = line_height
      @align = align
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

    # "left" / "center" / "right" (case-insensitive) → the symbol;
    # anything else (nil included) = the default left alignment.
    private def parse_align(value : String?) : Symbol?
      case value.try(&.downcase)
      when "center" then :center
      when "right"  then :right
      when "left"   then :left
      else               nil
      end
    end

    def style_class : String?
      "label"
    end

    # Retained paint (see paint_cache.cr): content = text + formatting
    # (BY VALUE — immediate-mode apps build a fresh Label every
    # frame). Selectable labels cache too, but not while their context
    # menu is open (its popup must render through #paint_selectable) or
    # while a non-collapsed GLOBAL selection exists — every cell repaints
    # its slice of the highlight, and the gesture itself lives in
    # TextSelection (Context#begin_frame), so press/drag frames replay
    # fine: a collapsed caret paints nothing.
    # A `wrap: false` label without responsive width keys is
    # WIDTH-INDEPENDENT (the galley is natural, `fit` is a no-op in an
    # unclamped cell) — its key drops the width terms, which is what
    # lets a flex MEASURE cell (full container width) hit the entry
    # the real (slot-width) pass stored.
    def paint_cache_key(ui : Ui)
      return nil if @preset_runs
      id = cache_id(ui)
      ctx = ui.ctx
      if @userselect
        # SECONDARY presses open the context menu; primary and
        # secondary buttons carry separate press state.
        return nil if ctx.input.secondary_pressed? ||
                      ctx.input.secondary_down? ||
                      ctx.input.secondary_released?
        return nil if ctx.popup_open?("context_menu_#{id.value}")
        return nil if ctx.text_selection.any_selection?
      end
      state = ctx.memory.interaction_state(id)
      base = style_vars(ui, id)
      stated = state.nil? ? base : style_vars(ui, id, state)
      # The font family rides the resolved style: a bag's
      # "font_family" key beats the base Style's field (the same
      # merge order as #ui's `style`). Fold it BY VALUE — a family
      # swap (`ctx.style.font_family = …`) mutates the SHARED Style
      # in place, so object identity alone would replay the old
      # face's baked glyphs after the cut switch.
      family = stated.str?("font_family") || base.str?("font_family") ||
               ui.style.font_family
      # Width terms only when the output depends on the width:
      # wrapping labels and responsive-sized ones.
      width_terms = @wrap != false ||
                    base.f64?("width") || base.str?("width") ||
                    base.f64?("min_width") || base.str?("min_width") ||
                    base.f64?("max_width") || base.str?("max_width")
      if width_terms
        ({"label", @rich.text, @rich.size, @rich.color, @rich.bold?,
         @rich.italic?, @rich.underline?, @rich.strikethrough?,
         @wrap, @align, @userselect, @line_height,
         ui.layout.vertical?, ui.wrap_x, ui.max_rect.width,
         ui.available_width, base.object_id, stated.object_id,
         ui.style.object_id, @style_override.try(&.hash),
         family}).hash
      else
        ({"label", @rich.text, @rich.size, @rich.color, @rich.bold?,
         @rich.italic?, @rich.underline?, @rich.strikethrough?,
         @wrap, @align, @userselect, @line_height,
         ui.layout.vertical?, ui.wrap_x, base.object_id,
         stated.object_id, ui.style.object_id,
         @style_override.try(&.hash), family}).hash
      end
    end

    # #ui's non-paint side effects on the selectable path: the text
    # cursor over hovered labels and the cell's re-registration — a
    # paint-cache replay must keep the galley hit-testable for the
    # global selection gesture (TextSelection#reregister refreshes the
    # geometry from the replayed Response#rect).
    def cache_replay(ui : Ui, response : Response) : Nil
      return unless @userselect
      ui.ctx.set_cursor_icon(Egui::CursorIcon::Text) if response.hovered?
      # response.id, NOT cache_id(ui) — the replay minted this widget's
      # id span already, so peeking the next id would hand back the
      # SIBLING below.
      ui.ctx.text_selection.reregister(response.id, response.rect)
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + StyleProps.sizable +
        [StyleProp.new("padding", :box),
         # A flat fill behind the text (CSS `background` on a text
         # element) — resolved through the one cascade order in
         # Label#ui, painted only when a layer actually sets it.
         StyleProp.new("background", :color),
         StyleProp.new("text_align", :string)]
    end

    def inspector_label : String?
      @rich.text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id)
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
      # Horizontal placement: the #align parameter or the `text_align`
      # style key — resolved once, before sizing (an aligned label in
      # a vertical layout stretches, see below).
      align = self.align || parse_align(class_vars.str?("text_align"))
      if (preset = @preset_runs)
        # Preset runs (syntax-highlighted code): colors already baked
        # in — the no-mono-stack retint would erase them.
        runs = preset
      else
        runs = @rich.runs(style.font_size, style.visuals.text_color,
          run_size, run_bold)
        # Code blocks share the inline-code fallback: without a mono
        # stack they draw in the proportional font — retint them.
        runs = RichText.fade_code_runs(runs, style.visuals) if ui.ctx.mono_fonts.nil?
      end
      # Runs may carry their own family (RichText#code — code blocks):
      # resolve those through ctx.fonts_for for BOTH measuring and
      # drawing; the base runs measure through the weight-resolved
      # stack (`fonts` above — a real cut face when one matched).
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ui.ctx.fonts_for(family, bold, italic) }
      # Default (nil): wrap where the label owns the rest of the line
      # — a vertical layout (upstream `TextWrapMode::Wrap`), the same
      # rule a TextArea wraps by (against the region width). In a
      # WRAP-CAPABLE horizontal row (#horizontal / wrap strips) a
      # label stays inline (`Extend`) unless even a FRESH line cannot
      # hold it (unwrapped text wider than the whole row) — then it
      # wraps against the row width and the row machinery breaks it
      # onto a full line of its own. In a single-line row
      # (`wrap: false`) there is NO fresh line to break to: the
      # default extends (clipped at the region edge, like upstream)
      # — wrapping there meant wrapping against the end-of-row
      # sliver, char-breaking the text into a one-glyph-wide column.
      # A zero remaining width would char-break every glyph onto its
      # own row — treat it as unbounded instead.
      wrap = @wrap
      if wrap.nil?
        if ui.layout.vertical?
          wrap = true
        elsif ui.wrap_x
          natural = fonts.layout(runs, nil, resolve, @line_height).size.x
          wrap = natural + pad.horizontal > ui.max_rect.width
        else
          wrap = false
        end
      end
      available = ui.available_width
      # The width the label can actually count on when wrapping: in a
      # WRAP-CAPABLE horizontal row (#horizontal / wrap strips) a
      # label that outgrows the remainder moves to a fresh FULL line —
      # wrap against that, never against the sliver (a room of one
      # glyph char-breaks the text into a vertical column). In a
      # single-line row only an EXPLICIT `wrap: true` ever wraps, and
      # the sliver is the space the label owns there.
      wrap_base = ui.layout.horizontal? && ui.wrap_x ? ui.max_rect.width
                                                      : available
      room = (wrap ? wrap_base : available) - pad.horizontal
      max_width = wrap && room > 0.0 ? room : nil
      galley = fonts.layout(runs, max_width, resolve, @line_height)

      size = galley.size + Vec2.new(pad.horizontal, pad.vertical)
      # A :center/:right label is BLOCK-LEVEL in a vertical layout
      # (CSS `text-align` semantics): it stretches to the available
      # width so the alignment has room to act — hugging its content
      # there would make center/right a silent no-op. Horizontal rows
      # keep the hugging size (the row cell already sizes it).
      if (align == :center || align == :right) && ui.layout.vertical?
        size = Vec2.new({size.x, available}.max, size.y)
      end
      # Responsive size keys are the last word on each axis (width
      # overrides the wrapped galley width; text centers in the rect).
      size = styled_size(size, class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id,
        @userselect ? Sense.click_and_drag : Sense.none)

      # CSS `background` on a text element: a value resolved through
      # the one cascade order (inline `style:` → the inspector's
      # per-element override → the class chain) paints a flat rect
      # over the whole allocated box, behind the text. Nothing in the
      # default themes sets it, so an ordinary label never paints one
      # — this is the NativeHTML swatch idiom
      # (`ui.p(" ", style: "background: …", width:, height:)`).
      if (bg = cascade_color?("background", ui, id, nil))
        ui.painter.rect(rect, 0.0, bg)
      end

      # The text lives in the content box (rect minus padding),
      # vertically centered. A host may clamp the rect below the
      # galley's height (the max-size rule at a region edge — a status
      # strip shorter than the label): top-aligning from the padding
      # then spills the text past the panel's clip and cuts its
      # descenders, so the row centers in the WHOLE rect instead — the
      # same too-tight-cell fallback Button uses. The fit test carries
      # a half-pixel tolerance: the unclamped case computes room as
      # (galley_h + pad) - pad, a float round-trip that can land a hair
      # under galley_h and would falsely take the fallback.
      room = rect.height - pad.vertical
      if room + 0.5 >= galley.size.y
        slack = {room - galley.size.y, 0.0}.max
        text_top = rect.min.y + pad.top + slack / 2.0
      else
        text_top = rect.center.y - galley.size.y / 2.0
      end
      text_top += @baseline_shift
      # Horizontal placement (#align, or the `text_align` style key):
      # the galley shifts by the free slack of the content box — a
      # label stretched by a width key (or sharing a row with taller
      # widgets) centers/right-aligns inside the rect it was given.
      slack_x = {rect.width - pad.horizontal - galley.size.x, 0.0}.max
      slack_x = case align
                when :center then slack_x / 2.0
                when :right  then slack_x
                else              0.0
                end
      content = Rect.from_min_size(
        Pos2.new(rect.min.x + pad.left + slack_x, text_top), galley.size)
      if @userselect
        paint_selectable(ui, response, id, content, galley, fonts,
          face_family, style, align)
      else
        ui.painter.paint_galley(content.min, galley, fonts,
          style.visuals.text_color, face_family, resolve, nil, nil,
          align)
      end

      response
    end

    # Text selection — the document-wide model (Context#text_selection):
    # this widget registers its galley as a selectable cell and paints
    # whatever slice of the global selection covers it. The gesture,
    # hotkeys and copy text all live in TextSelection; here only the
    # highlight strips (per row, behind the glyphs — same as TextEdit)
    # and the context menu remain.
    private def paint_selectable(ui : Ui, response : Response, id : Id,
                                 rect : Rect, galley : Galley,
                                 fonts : Fonts, face_family : String?,
                                 style : Style,
                                 align : Symbol? = nil) : Nil
      ctx = ui.ctx
      # Run stacks for caret/selection geometry: x_at must measure
      # each run's slice through ITS stack (code blocks draw mono
      # preset runs) or the highlight drifts off the drawn glyphs.
      resolve = ->(family : String?, bold : Bool, italic : Bool) {
        ctx.fonts_for(family, bold, italic)
      }

      flat = galley.rows.map(&.text).join
      row_starts = [] of Int32
      start = 0
      galley.rows.each do |row|
        row_starts << start
        start += row.text.size
      end

      ctx.set_cursor_icon(CursorIcon::Text) if response.hovered?

      ctx.text_selection.register(id, response.rect, rect, galley, fonts,
        resolve, align, flat, @rich.text, @rich.text.includes?('\n'))

      # Selection strips (index, x0, x1) — paint_galley lays them
      # between backgrounds and glyphs.
      segs = nil
      if (range = ctx.text_selection.range_for(id))
        sel_min, sel_max = range
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

      # Mouse copy: a secondary press (right-click) or a touch
      # long-press over the label opens Copy / Select all — acting on
      # the GLOBAL selection (a drag may span several labels). The
      # handlers run during the popup render, so Copy reads the text
      # captured when the menu opened; Select all re-points the global
      # anchor/focus at this cell.
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

      visuals = style.visuals
      ui.painter.paint_galley(rect.min, galley, fonts, visuals.text_color,
        face_family, resolve, segs, visuals.text_selection, align)
    end
  end
end
