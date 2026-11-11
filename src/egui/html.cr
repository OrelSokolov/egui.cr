# NativeHTML — the HTML element vocabulary (plans/NativeHTML.md §5).
#
# An OPT-IN module: `require "egui/html"` extends `Ui`/`Context` with
# the browser's element names as plain Crystal methods — `ui.div`,
# `ui.a`, `ui.h1` — mapped onto the engine's existing widgets. The
# core is untouched; every alias is a thin, documented delegation.
#
# Universal attributes (§5.4), accepted by every alias through
# `**attrs`:
#
#   classes:      String  — the style-class path (space-separated
#                           segments become the dotted path:
#                           "sidebar tab" → "sidebar.tab"; widgets
#                           chain it onto their element class, boxes
#                           style under it directly)
#   id:           String  — the widget's explicit id
#   style:        String  — inline overrides, CSS declaration syntax:
#                           "background: #3584e4; color: #fff"
#   title:        String  — a hover tooltip
#   disabled:     Bool    — render dimmed and non-interactive
#   hidden:       Bool    — skip rendering; an explicit `id:` keeps
#                           the widget's memory alive (HTML semantics)
#   data_testid:  String  — recorded in `Context#data_testids` for
#                           capybara selectors and the inspector
#   width:/height: Float64 — pin the element's size (as a pair; a
#                           lone axis is honored where the underlying
#                           widget sizes itself — img keeps aspect)
#
# Events are BLOCKS, never string callbacks: `ui.button("Save") {
# save }` is `onclick`, the Signal forms are `oninput`.
#
# Deliberately NOT wired (no engine semantics behind them — SPEC.md
# is the contract): `required`/`pattern`/`autocomplete` (no
# validation layer), `lang` (no fontchain effect), `role`/`aria-*`
# (no a11y layer yet), `tabindex` (Tab navigation not ported),
# `target:` (every link already opens through SystemPorts).

require "../egui"

module Egui
  module Html
    # "#rgb", "#rrggbb" or "#rrggbbaa" → Color32; nil on anything
    # else (the declaration is skipped, not guessed).
    def self.color(s : String) : Color32?
      return nil unless s.starts_with?('#')
      hex = s[1..]
      hex = hex.chars.map { |c| "#{c}#{c}" }.join if hex.size == 3
      return nil unless hex.size == 6 || hex.size == 8
      pair = ->(i : Int32) { hex[i, 2].to_u8?(16) }
      r = pair.call(0)
      g = pair.call(2)
      b = pair.call(4)
      a = hex.size == 8 ? pair.call(6) : 255_u8
      return nil unless r && g && b && a
      Color32.new(r, g, b, a)
    end

    # "key: value; key: value" → the parsed per-key pairs (empty
    # keys/values dropped).
    def self.declarations(style : String) : Array({String, String})
      style.split(';').map do |decl|
        key, _, val = decl.partition(':')
        {key.strip.downcase, val.strip}
      end.reject { |k, v| k.empty? || v.empty? }
    end

    # The widget-level `style:` vocabulary — exactly the WidgetStyle
    # fields (CSS spellings accepted alongside the engine keys).
    def self.widget_style(style : String) : WidgetStyle
      ws = WidgetStyle.new
      declarations(style).each do |key, val|
        case key
        when "background", "background-color"
          ws.background = color(val)
        when "color", "text-color", "text_color"
          ws.text_color = color(val)
        when "stroke", "border-color"
          ws.stroke = color(val)
        when "selection_fill"
          ws.selection_fill = color(val)
        when "separator-color", "separator_color"
          ws.separator_color = color(val)
        when "hyperlink-color", "hyperlink_color"
          ws.hyperlink_color = color(val)
        when "font-size", "font_size"
          ws.font_size = val.to_f64?
        when "font-family", "font_family"
          ws.font_family = val
        end
      end
      ws
    end

    # The mutable box paint parameters an inline `style:` may touch
    # on a container (nil = keep the call-site default). The
    # `position`/offset fields stay RAW strings (unit spellings like
    # "10%" pass through) — `ui.div` forwards them to `Ui#box`, whose
    # #box_positioning resolves them against the containing block.
    class BoxParams
      property fill : Color32?
      property stroke : Color32?
      property rounding : Float64?
      property corners : CornerRadii?
      property margin : Vec2?
      property position : String?
      property top : String?
      property right : String?
      property bottom : String?
      property left : String?

      def initialize(@fill = nil, @stroke = nil, @rounding = nil,
                     @corners = nil, @margin = nil,
                     @position = nil, @top = nil, @right = nil,
                     @bottom = nil, @left = nil)
      end
    end

    # The CSS `position` keywords, inline `style:` spelling → the
    # `Ui#box(position:)` symbols ("static"/unset read as nil — the
    # plain flow path).
    def self.position_sym(s : String?) : Symbol?
      case s
      when "relative" then :relative
      when "absolute" then :absolute
      when "fixed"    then :fixed
      else nil
      end
    end

    # The container-level `style:` vocabulary — the box (div) paint
    # parameters (CSS spellings accepted alongside the engine keys).
    def self.box_style(style : String, base : BoxParams) : BoxParams      declarations(style).each do |key, val|
        case key
        when "background", "background-color"
          base.fill = color(val)
        when "stroke", "border-color"
          base.stroke = color(val)
        when "border-radius", "rounding"
          # The CSS shorthand (1-4 radii, `px` optional): multi-value
          # parses per-corner, a single value stays the scalar it
          # always was.
          if (c = CornerRadii.parse?(val))
            if c.uniform?
              base.rounding = c.top_left
            else
              base.corners = c
            end
          else
            base.rounding = val.to_f64?
          end
        when "padding"
          if (n = val.to_f64?)
            base.margin = Vec2.new(n, n)
          end
        when "padding-x", "padding-left", "padding-right"
          if (n = val.to_f64?)
            m = base.margin || Vec2.zero
            base.margin = Vec2.new(n, m.y)
          end
        when "padding-y", "padding-top", "padding-bottom"
          if (n = val.to_f64?)
            m = base.margin || Vec2.zero
            base.margin = Vec2.new(m.x, n)
          end
        when "position"
          base.position = val
        when "top"
          base.top = val
        when "right"
          base.right = val
        when "bottom"
          base.bottom = val
        when "left"
          base.left = val
        end
      end
      base
    end
  end

  class WidgetStyle
    # Copy every non-nil field of `other` onto self — the inline
    # `style:` layering for widgets that already carry overrides.
    def overlay(other : WidgetStyle) : self
      @text_color = other.text_color if other.text_color
      @background = other.background if other.background
      @stroke = other.stroke if other.stroke
      @selection_fill = other.selection_fill if other.selection_fill
      @separator_color = other.separator_color if other.separator_color
      @hyperlink_color = other.hyperlink_color if other.hyperlink_color
      @font_size = other.font_size if other.font_size
      @font_family = other.font_family if other.font_family
      @button_padding = other.button_padding if other.button_padding
      self
    end
  end

  class Context
    # `data_testid:` registry (the HTML `data-testid` attribute):
    # testid → the widget's Id, last writer wins, stable across
    # frames while the widget lives. Populated by the html aliases;
    # capybara selectors and the inspector read it to address widgets
    # without knowing the id hierarchy.
    def data_testids : Hash(String, Id)
      @data_testids ||= {} of String => Id
    end
  end

  class Context
    # One open list (`<ul>`/`<ol>`) in the frame — the innermost list
    # is the stack's last entry, one per nesting level. `li` reads the
    # top entry: bullet marker for a `ul`, the next number of its own
    # `ol` for an `ol` (a nested `ol` restarts at its `start`, like
    # the browser — hierarchical "2.1." markers are CSS counters, not
    # HTML). Lives on the Context because list bodies render through
    # child Ui instances; a stack — not a single counter — is what
    # keeps nested lists independent: a `ul` inside an `ol` shows
    # glyphs, and closing the nested list restores the outer
    # numbering untouched.
    class HTMLListScope
      # The number shown by this list's most recent `li` (start - 1
      # before any li).
      property counter : Int32

      def initialize(@ordered : Bool, start : Int32)
        @counter = start - 1
      end

      def ordered? : Bool
        @ordered
      end
    end

    property html_list_scopes : Array(HTMLListScope) = Array(HTMLListScope).new

    # `data_testid:` registry (the HTML `data-testid` attribute):
    # testid → the widget's Id, last writer wins, stable across
    # frames while the widget lives. Populated by the html aliases;
    # capybara selectors and the inspector read it to address widgets
    # without knowing the id hierarchy.
    def data_testids : Hash(String, Id)
      @data_testids ||= {} of String => Id
    end
  end

  class Ui
    # === shared attribute plumbing (private) =========================

    private def html_str(attrs, key : Symbol) : String?
      attrs[key]?.as?(String)
    end

    private def html_f64(attrs, key : Symbol) : Float64?
      case v = attrs[key]?
      when Float64 then v
      when Int32   then v.to_f64
      else nil
      end
    end

    private def html_hidden?(attrs) : Bool
      attrs[:hidden]? == true
    end

    private def html_disabled?(attrs) : Bool
      attrs[:disabled]? == true
    end

    # `hidden: true` skips the element; an explicit id keeps its
    # memory cell alive (HTML display:none — state survives).
    private def html_skip(attrs) : Nil
      if (id = html_str(attrs, :id))
        ctx.memory.use_id(Id.from(id))
      end
    end

    # Space-separated classes → the dotted style path.
    private def html_class_path(attrs) : String?
      html_str(attrs, :classes).try do |c|
        c.strip.empty? ? nil : c.strip.gsub(' ', '.')
      end
    end

    # A block under an optional style scope ("card" makes inner
    # widgets chain "card.button" etc.).
    private def html_scope(classes : String?, &block : Ui ->)
      if classes && !classes.empty?
        with_style_scope(classes) { |ui| block.call(ui) }
      else
        block.call(self)
      end
    end

    # The common path of every widget alias: id → inline style →
    # classes scope → disabled → sizing → add → tooltip → testid.
    # Returns nil when hidden.
    private def html_widget(widget : Widget, attrs) : Response?
      return html_skip(attrs) if html_hidden?(attrs)
      if (id = html_str(attrs, :id))
        widget.with_id(id)
      end
      if (style = html_str(attrs, :style))
        parsed = Html.widget_style(style)
        widget.style { |ws| ws.overlay(parsed) }
      end
      w = html_f64(attrs, :width)
      h = html_f64(attrs, :height)
      response = nil
      html_scope(html_class_path(attrs)) do |ui|
        add_one = ->(u : Ui) do
          if w && h
            u.add_sized(Vec2.new(w, h), widget)
          else
            u.add(widget)
          end
        end
        if html_disabled?(attrs)
          ui.enabled(false) { |dis| response = add_one.call(dis) }
        else
          response = add_one.call(ui)
        end
      end
      resp = response.not_nil!
      resp = resp.on_hover_text(html_str(attrs, :title).not_nil!) if attrs[:title]?
      if (testid = html_str(attrs, :data_testid))
        ctx.data_testids[testid] = resp.id
      end
      resp
    end

    # The container twin of #html_widget for method-based elements
    # (panels, selects): scope + disabled + hidden; the block runs
    # with the prepared Ui. Returns nil when hidden. Pass
    # `scoped: false` when the element itself already scopes its
    # contents (box's `style_class:`) — scopes NEST by dots, so an
    # outer "card" around a box scoped "card" would chain
    # "card.card.button" instead of "card.button".
    private def html_block(attrs, scoped : Bool = true, &block : Ui ->)
      return html_skip(attrs) if html_hidden?(attrs)
      if scoped && (path = html_class_path(attrs))
        html_scope(path) { |ui| html_run(ui, attrs, &block) }
      else
        html_run(self, attrs, &block)
      end
    end

    private def html_run(ui : Ui, attrs, &block : Ui ->)
      if html_disabled?(attrs)
        ui.enabled(false) { |dis| block.call(dis) }
      else
        block.call(ui)
      end
    end

    # === block structure (§5.2 direct aliases) =======================

    # `<div>` — the plain block container: `ui.box` in column flow.
    # `classes:` styles the box under the class path; inline `style:`
    # touches the box paint (background/border/padding/rounding) and
    # positioning — `position: fixed; top: 10; left: 10` (CSS §position,
    # `absolute`/`fixed` take the box out of the flow, `relative`
    # shifts it; offsets take units: `10`, `"10%"`, `"2vw"`).
    def div(**attrs, &block : Ui ->) : Rect?
      return html_skip(attrs) if html_hidden?(attrs)
      params = Html::BoxParams.new
      if (style = html_str(attrs, :style))
        Html.box_style(style, params)
      end
      rect = nil
      html_block(attrs, scoped: false) do |ui|
        rect = ui.box(
          style_class: html_class_path(attrs),
          fill: params.fill, stroke: params.stroke,
          rounding: params.rounding || params.corners.try(&.max) || 6.0,
          margin: params.margin,
          corners: params.corners,
          position: Html.position_sym(params.position),
          top: params.top, right: params.right,
          bottom: params.bottom, left: params.left,
          &block
        )
      end
      rect
    end

    # `<span>` — the inline container: a no-wrap horizontal row.
    def span(**attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs) do |ui|
        ui.horizontal(wrap: false) { |row| rect = block.call(row) }
      end
      rect
    end

    # `<header>` / `<footer>` / `<nav>` / `<aside>` / `<main>` — the
    # layout regions, delegating to the Context panels. `nav`/`aside`
    # take `side: :left|:right` (nav defaults left, aside right).
    def header(**attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs) do |ui|
        rect = ui.ctx.top_panel(id: html_str(attrs, :id) || "header",
          &block)
      end
      rect
    end

    def footer(**attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs) do |ui|
        rect = ui.ctx.bottom_panel(id: html_str(attrs, :id) || "footer",
          &block)
      end
      rect
    end

    def nav(side : Symbol = :left, **attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs) do |ui|
        rect = ui.ctx.side_panel(side,
          id: html_str(attrs, :id) || "nav", &block)
      end
      rect
    end

    def aside(side : Symbol = :right, **attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs) do |ui|
        rect = ui.ctx.side_panel(side,
          id: html_str(attrs, :id) || "aside", &block)
      end
      rect
    end

    def main(**attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs) do |ui|
        rect = ui.ctx.central_panel(id: html_str(attrs, :id) || "main",
          &block)
      end
      rect
    end

    # `<dialog>` — the modal card: `Context#modal`. Returns the
    # footer button clicked this frame (nil otherwise).
    def dialog(id : String = "dialog", width : Float64 = 480.0,
               title : String? = nil, buttons : Array(String) = [] of String,
               **attrs, &block : Ui ->) : String?
      ctx.modal(id: id, width: width, title: title, buttons: buttons,
        &block)
    end

    # `<iframe>` — an embedded floating window over the content:
    # `Context#embedded_window`.
    def iframe(id : String, title : String? = nil, width : Float64 = 460.0,
               frame : Symbol = :classic, **attrs, &block : Ui ->) : Bool
      ctx.embedded_window(id, title, width, frame, &block)
    end

    # === text (§5.3 sugar) ===========================================

    # `<p>` — a paragraph: a label with breathing room above and
    # below (0.35 line heights; the flow's item spacing rides on top).
    def p(text : String, **attrs) : Response?
      line_h = style.font_size * Fonts::LINE_H_FACTOR
      allocate_space(Vec2.new(0.0, line_h * 0.35))
      html_widget(Label.new(text), attrs).tap do
        allocate_space(Vec2.new(0.0, line_h * 0.35))
      end
    end

    # `<h1>`..`<h6>` — the CSS heading scale (2em…0.67em, bold).
    {% for pair in { {1, 2.0}, {2, 1.5}, {3, 1.17},
                     {4, 1.0}, {5, 0.83}, {6, 0.67} } %}
      def h{{ pair[0].id }}(text : String, **attrs) : Response?
        html_widget(Label.new(RichText.new(text)
          .size(style.font_size * {{ pair[1] }}).bold), attrs)
      end
    {% end %}

    # `<strong>`/`<em>`/`<code>`/`<mark>`/`<small>`/`<sub>`/`<sup>` —
    # styled text runs (RichText). `mark` tints with the text
    # selection color; `sub`/`sup` shrink to 0.75em and shift the
    # baseline below/above the line (see #html_script_run).
    def strong(text : String, **attrs) : Response?
      html_widget(Label.new(RichText.new(text).bold), attrs)
    end

    def em(text : String, **attrs) : Response?
      html_widget(Label.new(RichText.new(text).italic), attrs)
    end

    def code(text : String, **attrs) : Response?
      html_widget(Label.new(RichText.new(text).code), attrs)
    end

    def mark(text : String, **attrs) : Response?
      html_widget(Label.new(RichText.new(text)
        .color(ctx.style.visuals.text_selection)), attrs)
    end

    def small(text : String, **attrs) : Response?
      html_widget(Label.new(RichText.new(text)
        .small(style.font_size)), attrs)
    end

    # sub: baseline dropped 0.25em below the parent line's; sup:
    # raised 0.35em above it (browser ballpark for
    # `vertical-align: sub/super` at a 0.75em script size).
    def sub(text : String, **attrs) : Response?
      html_script_run(text, style.font_size * 0.25, attrs)
    end

    def sup(text : String, **attrs) : Response?
      html_script_run(text, -style.font_size * 0.35, attrs)
    end

    # sub/sup core: the 0.75em run on a FULL line-height rect (via
    # Label#line_height inflation), so the row's cross-axis centering
    # (#allocate_space centers every widget by its rect height)
    # aligns its em center with the sibling labels' — and the galley
    # shifted by the baseline delta: the parent line's baseline sits
    # (asc+desc)/2 below the row-box center (WrapState#emit_row's
    # shared-baseline formula), so the shift is that offset plus the
    # drop/raise, minus the small run's own em-center offset. In a
    # horizontal row the script also hugs its base letter: the row's
    # item_spacing.x is a WORD gap, an inline script box has none.
    private def html_script_run(text : String, drop : Float64,
                                attrs) : Response?
      size = style.font_size
      asc, desc = fonts.metrics_at(size)
      s_asc, s_desc = fonts.metrics_at(size * 0.75)
      label = Label.new(RichText.new(text).size(size * 0.75))
      label.line_height = Fonts::LINE_H_FACTOR / 0.75
      label.baseline_shift =
        (asc + desc) / 2.0 + drop - (s_asc + s_desc) / 2.0
      if layout.horizontal? && cursor.x > max_rect.min.x
        self.cursor = Pos2.new(
          cursor.x - style.spacing.item_spacing.x, cursor.y)
      end
      html_widget(label, attrs)
    end

    # `<pre>` — preformatted monospace text, no soft wrap, in its own
    # horizontal scroll region (`hbar: :bottom`). The height is the
    # text's own (one line height per source line, plus padding) — a
    # content-sized block like the browser's `<pre>`, NOT the full
    # available height a bare scroll area would take (in an unbounded
    # parent that would swallow the rest of the page).
    def pre(text : String, **attrs) : Rect?
      line_h = style.font_size * Fonts::LINE_H_FACTOR
      height = text.count('\n') * line_h + line_h + 8.0
      rect = nil
      html_block(attrs) do |ui|
        rect = ui.scroll_area(max_height: height, hbar: :bottom) do |area|
          area.rich(RichText.new(text).code, wrap: false)
        end
      end
      rect
    end

    # `<br>` — a hard wrap break: pushes the rest of the row to the
    # next line through #end_line, the requested-break layout
    # primitive (works in no-wrap rows like span, where the implicit
    # wrap of #allocate_space never fires). A no-op in vertical flow,
    # where every widget already starts its own line.
    def br : Nil
      end_line
    end

    # `<hr>` — the horizontal rule.
    def hr(**attrs) : Response?
      html_widget(Separator.new, attrs)
    end

    # `<blockquote>` — a quoted block: a padded frame with an accent
    # stroke on the LEFT edge only.
    def blockquote(**attrs, &block : Ui ->) : Rect?
      return html_skip(attrs) if html_hidden?(attrs)
      accent = style.visuals.selection_fill
      left = SideStroke.new(3.0, accent)
      none = SideStroke.new(0.0, accent)
      rect = nil
      html_block(attrs, scoped: false) do |ui|
        rect = ui.box(
          fill: ui.style.visuals.panel_fill,
          stroke_sides: StrokeSides.new(none, none, none, left),
          margin: Vec2.new(12.0, 8.0),
          style_class: html_class_path(attrs),
          &block
        )
      end
      rect
    end

    # `<fieldset>` — a framed group with its `<legend>` caption riding
    # the TOP border, the browser's geometry: the box's top side stays
    # off (width 0) and is redrawn manually as two segments around the
    # caption — bold text vertically centered on the border line. The
    # painter commands land after the box's, so the caption draws on
    # top of the frame. `fieldset { stroke: dim }` in the gallery's
    # ECSS: the frame is the theme's dim window stroke.
    def fieldset(legend : String, **attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs, scoped: false) do |ui|
        stroke = ui.style.visuals.window_stroke
        off = SideStroke.new(0.0, stroke)
        on = SideStroke.new(1.0, stroke)
        legend_size = ui.ctx.fonts_for(nil, bold: true)
          .measure(legend, ui.style.font_size * 0.9)
        rect = ui.box(
          stroke_sides: StrokeSides.new(off, on, on, on),
          style_class: html_class_path(attrs),
          margin: Vec2.new(10.0, 8.0)) do |inner|
          # the caption's lower half hangs into the frame: content
          # clears it by half a legend line
          inner.allocate_space(Vec2.new(0.0, legend_size.y * 0.5))
          block.call(inner)
        end
        paint_legend_on_border(ui, rect.not_nil!, legend, legend_size, stroke)
      end
      rect
    end

    # The two top-border segments + the caption between them. The line
    # sits at edge + width/2 (the same centerline an ON top side would
    # occupy) and is shortened by the corner rounding like the sides.
    private def paint_legend_on_border(ui : Ui, frame : Rect, legend : String,
                                       legend_size : Vec2,
                                       stroke : Color32) : Nil
      gap = 4.0
      rad = 6.0
      y = frame.min.y + 0.5
      x0 = frame.min.x + 14.0
      x1 = x0 + legend_size.x
      left_end = x0 - gap
      right_start = x1 + gap
      seg_left = frame.min.x + rad
      seg_right = frame.max.x - rad
      if left_end > seg_left
        ui.painter.line(Pos2.new(seg_left, y), Pos2.new(left_end, y),
          1.0, stroke)
      end
      if right_start < seg_right
        ui.painter.line(Pos2.new(right_start, y), Pos2.new(seg_right, y),
          1.0, stroke)
      end
      ui.painter.text(Pos2.new(x0, y), legend,
        ui.style.font_size * 0.9, ui.style.visuals.text_color, bold: true)
    end

    # === lists (§5.3 — the one new primitive) ========================

    # `<ul>` — an indented list of `li` rows (bullet markers).
    def ul(**attrs, &block : Ui ->) : Rect?
      list_block(attrs, ordered: false, start: 1, &block)
    end

    # `<ol start: 1>` — a numbered list; `li` rows number themselves
    # through the list scope stack (a nested `ol` restarts at its own
    # `start`, like the browser).
    def ol(start : Int32 = 1, **attrs, &block : Ui ->) : Rect?
      list_block(attrs, ordered: true, start: start, &block)
    end

    # `<li>` — one list row: a marker (bullet or the `ol` counter)
    # plus the content. Text form and block form (nested lists).
    def li(text : String, **attrs) : Response?
      resp = nil
      li_row(attrs) do |ui|
        resp = ui.label(text)
      end
      resp
    end

    def li(**attrs, &block : Ui ->) : Rect?
      rect = nil
      li_row(attrs) { |ui| rect = block.call(ui) }
      rect
    end

    private def list_block(attrs, ordered, start, &block : Ui ->) : Rect?
      ctx.html_list_scopes.push(Context::HTMLListScope.new(ordered, start))
      begin
        rect = nil
        html_block(attrs, scoped: false) do |ui|
          rect = ui.box(margin: Vec2.new(14.0, 2.0),
            style_class: html_class_path(attrs)) do |inner|
            block.call(inner)
          end
        end
        rect
      ensure
        ctx.html_list_scopes.pop
      end
    end

    # Marker-to-content gap, HTML style: a browser's outside marker
    # hugs the text (its right edge sits at the content box edge), so
    # the gap is a small fixed tab — not the layout's item_spacing.
    LI_MARKER_GAP = 5.0

    private def li_row(attrs, &block : Ui ->)
      html_scope(html_class_path(attrs)) do |ui|
        ui.horizontal(wrap: false) do |row|
          row.label(li_marker)
          # The label already advanced the cursor by item_spacing.x —
          # pull it back so the net gap is exactly LI_MARKER_GAP.
          row.cursor = row.layout.advance(row.cursor, Vec2.zero,
            Vec2.new(LI_MARKER_GAP - row.style.spacing.item_spacing.x, 0.0))
          block.call(row)
        end
      end
    end

    # The innermost open list decides the marker: a bullet in a `ul`
    # (or outside any list), otherwise that `ol`'s own counter —
    # plain HTML numbering, a nested list restarts at its `start`.
    private def li_marker : String
      scopes = ctx.html_list_scopes
      return "•" if scopes.empty? || !scopes.last.ordered?
      scopes.last.counter += 1
      "#{scopes.last.counter}."
    end

    # === links, media, forms (§5.2 direct aliases) ===================

    # `<a>` — a hyperlink. Two forms: `a("Docs", href: url)` and the
    # bare `a(href: url)` (the URL is the label). Every link opens
    # through SystemPorts (the browser's default target behavior).
    def a(text : String, href : String, **attrs) : Response?
      html_widget(Hyperlink.new(text, href), attrs)
    end

    def a(href : String, **attrs) : Response?
      a(href, href, **attrs)
    end

    # `<img src: alt:>` — an image file (decoded and cached per path
    # through `Context#load_image`); width/height default to the
    # image's pixel size (a lone axis keeps the aspect), `alt:` is
    # the tooltip fallback when `title:` is absent.
    def img(src : String, **attrs) : Response?
      return html_skip(attrs) if html_hidden?(attrs)
      natural = ctx.image_size(src) || Vec2.new(100.0, 100.0)
      w = html_f64(attrs, :width)
      h = html_f64(attrs, :height)
      size = if w && h
               Vec2.new(w, h)
             elsif w
               Vec2.new(w, w / natural.x * natural.y)
             elsif h
               Vec2.new(h / natural.y * natural.x, h)
             else
               natural
             end
      texture = ctx.load_image(src)
      resp = html_widget(Image.new(texture, size), attrs)
      if resp && (tip = html_str(attrs, :title) || html_str(attrs, :alt))
        resp.on_hover_text(tip)
      end
      resp
    end

    # `<input>` — a text field (HTML `input[type=text]`):
    # `placeholder:` is the hint. Buffer form (block = oninput) and
    # Signal form (write-back, no block).
    def input(buffer : String, **attrs, &on_change : String ->) : Response?
      resp = html_widget(TextEdit.new(buffer,
        hint: html_str(attrs, :placeholder)), attrs)
      if resp && resp.changed? && (text = resp.widget_text)
        on_change.call(text)
      end
      resp
    end

    def input(sig : Signal(String), **attrs) : Response?
      resp = html_widget(TextEdit.new(sig.value,
        hint: html_str(attrs, :placeholder)), attrs)
      if resp && resp.changed? && (text = resp.widget_text)
        sig.value = text
      end
      resp
    end

    # `<select>` — a dropdown. `selected:` the current option; the
    # block is `onchange`. Signal form writes the pick back.
    def select(id : String, selected : String, options : Array(String),
               **attrs, &on_select : String ->) : Bool?
      picked = false
      html_block(attrs) do |ui|
        picked = ui.combo_box(id, selected, options) do |opt|
          on_select.call(opt)
        end
      end
      picked
    end

    def select(id : String, sig : Signal(String),
               options : Array(String), **attrs) : Bool?
      picked = false
      html_block(attrs) do |ui|
        picked = ui.combo_box(id, sig, options)
      end
      picked
    end

    # `<progress>`/`<meter>` — the progress bar (0.0..1.0).
    def progress(fraction : Float64, text : String? = nil,
                 **attrs) : Response?
      html_widget(ProgressBar.new(fraction, text), attrs)
    end

    def meter(fraction : Float64, text : String? = nil,
              **attrs) : Response?
      progress(fraction, text, **attrs)
    end

    # `<details>` — a collapsible section; `summary:` is the header
    # line, `open:` the initial state. The block is the body.
    def details(summary : String, open : Bool = false, **attrs,
                &block : Ui ->) : Response?
      return html_skip(attrs) if html_hidden?(attrs)
      header = CollapsingHeader.new(summary, default_open: open)
      resp = nil
      html_scope(html_class_path(attrs)) do |ui|
        resp = header.show(ui) { |body| block.call(body) }
      end
      if (r = resp) && (title = html_str(attrs, :title))
        r = r.on_hover_text(title)
      end
      resp
    end
  end
end
