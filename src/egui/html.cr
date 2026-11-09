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
    # on a container (nil = keep the call-site default).
    class BoxParams
      property fill : Color32?
      property stroke : Color32?
      property rounding : Float64?
      property margin : Vec2?

      def initialize(@fill = nil, @stroke = nil, @rounding = nil,
                     @margin = nil)
      end
    end

    # The container-level `style:` vocabulary — the box (div) paint
    # parameters (CSS spellings accepted alongside the engine keys).
    def self.box_style(style : String, base : BoxParams) : BoxParams
      declarations(style).each do |key, val|
        case key
        when "background", "background-color"
          base.fill = color(val)
        when "stroke", "border-color"
          base.stroke = color(val)
        when "border-radius", "rounding"
          base.rounding = val.to_f64?
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
    # The `<ol>` frame-local counter (nil outside an ol — `li` shows
    # the bullet marker then). Lives on the Context because the list
    # body renders through child Ui instances.
    property html_ol_counter : Int32? = nil

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
    # touches the box paint (background/border/padding/rounding).
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
          rounding: params.rounding || 6.0,
          margin: params.margin,
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
    # selection color; `sub`/`sup` shrink to 0.75em (the engine does
    # not shift baselines yet — SPEC.md records the deviation).
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

    def sub(text : String, **attrs) : Response?
      html_widget(Label.new(RichText.new(text)
        .size(style.font_size * 0.75)), attrs)
    end

    def sup(text : String, **attrs) : Response?
      html_widget(Label.new(RichText.new(text)
        .size(style.font_size * 0.75)), attrs)
    end

    # `<pre>` — preformatted monospace text, no soft wrap, in its own
    # horizontal scroll region (`hbar: :bottom`).
    def pre(text : String, **attrs) : Rect?
      rect = nil
      html_block(attrs) do |ui|
        rect = ui.scroll_area(hbar: :bottom) do |area|
          area.rich(RichText.new(text).code, wrap: false)
        end
      end
      rect
    end

    # `<br>` — a hard wrap break: pushes the rest of the row to the
    # next line (a no-op in vertical flow, where every widget already
    # starts its own line).
    def br : Nil
      if layout.horizontal?
        allocate_space(Vec2.new(available_width, 0.0))
      end
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

    # `<fieldset>` — a framed group with its `<legend>` caption on
    # the first row (bold, slightly smaller — inside the frame).
    def fieldset(legend : String, **attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs, scoped: false) do |ui|
        rect = ui.box(style_class: html_class_path(attrs),
          margin: Vec2.new(10.0, 8.0)) do |inner|
          inner.rich(RichText.new(legend)
            .size(inner.style.font_size * 0.9).bold)
          block.call(inner)
        end
      end
      rect
    end

    # === lists (§5.3 — the one new primitive) ========================

    # `<ul>` — an indented list of `li` rows (bullet markers).
    def ul(**attrs, &block : Ui ->) : Rect?
      list_block(attrs, &block)
    end

    # `<ol start: 1>` — a numbered list; `li` rows number themselves
    # through the frame-local counter.
    def ol(start : Int32 = 1, **attrs, &block : Ui ->) : Rect?
      ctx.html_ol_counter = start
      begin
        list_block(attrs, &block)
      ensure
        ctx.html_ol_counter = nil
      end
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

    private def list_block(attrs, &block : Ui ->) : Rect?
      rect = nil
      html_block(attrs, scoped: false) do |ui|
        rect = ui.box(margin: Vec2.new(14.0, 2.0),
          style_class: html_class_path(attrs)) do |inner|
          block.call(inner)
        end
      end
      rect
    end

    private def li_row(attrs, &block : Ui ->)
      marker = if (n = ctx.html_ol_counter)
                 ctx.html_ol_counter = n + 1
                 "#{n}."
               else
                 "•"
               end
      html_scope(html_class_path(attrs)) do |ui|
        ui.horizontal(wrap: false) do |row|
          row.label(marker)
          row.allocate_space(Vec2.new(6.0, 0.0))
          block.call(row)
        end
      end
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
