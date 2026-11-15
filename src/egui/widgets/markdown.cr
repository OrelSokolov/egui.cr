# Markdown widget — a three-stage pipeline: markdown → HTML → EXML
# → the engine.
#
#   1. `Markdown.parse` — the pure block model (headings, paragraphs,
#      fenced code, quotes, lists, rules, images, GFM tables),
#      unchanged and headless-testable.
#   2. `Markdown.to_html` — the blocks as an EXPLICIT HTML document:
#      `<h1>`, `<p>`, `<pre lang=…>`, `<blockquote>`, `<ul>/<ol>/<li>`,
#      `<hr/>`, `<img …>`, `<table><tr><th|td>` with inline markup
#      (`**bold**`, `*italic*`, `***both***`, `` `code` ``, `~~strike~~`,
#      `[label](url)`) converted to `<strong>/<em>/<code>/<del>/<a>`.
#   3. `#ui` — the HTML parsed as an EXML fragment (`Exml.parse_fragment`)
#      and rendered by the ENGINE (`Exml::Renderer`): every emitted tag
#      is a custom element whose handler draws through the standard
#      widgets (RichLabel with preset runs for inline styles, the
#      highlighter for code fences, TableTextRenderer for tables, real
#      Image widgets for images).
#
# The HTML string and the parsed node tree are cached on the CLASS,
# keyed by source — the widget is rebuilt every frame. `Markdown.parse`
# stays the public headless API (specs test it without a Context).

require "highlight_cr"

module Egui
  class Markdown
    include Widget

    # HTML-ish heading scale over the style's font size; all bold.
    # h1/h2 are GitHub's 2em/1.5em — 32/24px at the default 16px body.
    HEADING_SCALES = {2.0, 1.5, 1.15, 1.0, 0.9, 0.85}
    # Fenced-code background per theme (non-inline blocks; the inline
    # chip is RichLabel::INLINE_CODE_BG): GitHub's light tint and its
    # dark counterpart.
    CODE_BG       = Color32.rgba(0xF0, 0xF1, 0xF3, 255)
    CODE_BG_DARK  = Color32.rgba(0x16, 0x1B, 0x22, 255)
    # Horizontal rules carry at least this much breathing room above
    # and below the line.
    HR_PAD = 5.0
    # Horizontal rule stroke per theme: soft gray, ~70% opacity.
    HR_COLOR      = Color32.rgba(0xD1, 0xD9, 0xE0, 0xB3)
    HR_COLOR_DARK = Color32.rgba(0x30, 0x36, 0x3D, 0xB3)
    # Default horizontal reading padding (the text never touches the
    # window edges); override per widget with `pad_x:`.
    DEFAULT_PAD_X = 10.0
    # Body line-height (GitHub's `body { line-height: 1.5 }`): the roomy
    # line box is what lets the inline-code chip (1.4em tall) sit inside
    # the line instead of filling it edge to edge.
    BODY_LINE_H = 1.5
    # Headings keep it tighter (GitHub h1/h2 ≈ 1.25) — the large type
    # already carries enough air.
    HEADING_LINE_H = 1.25
    # Reader-page background per theme: a white page on light themes,
    # GitHub's dark canvas on dark ones — the page always contrasts
    # with the theme's text color. `#background` starts nil = follow
    # the theme; an explicit color always wins.
    PAGE_BG       = Color32.rgba(255, 255, 255, 255)
    PAGE_BG_DARK  = Color32.rgba(0x0D, 0x11, 0x17, 255)

    # One parsed block. `text` carries the STRIPPED content (markers
    # removed); heading `level` is 1-6, list items keep their number
    # (`ordered` false → bullet), an image block's `text` is the URL,
    # `alt` its alt text, `width_px` an explicit `<img width=…>` size
    # and `align` its horizontal alignment. A table's `text` holds the
    # rows joined by \n and \x1F (unit separator): first row = header.
    # A code block's `lang` is the fence info string's first word
    # (downcased; nil when the fence carries none).
    class Block
      getter kind : Symbol
      # List items append lazy-continuation lines to their text, so
      # `text` is mutable.
      property text : String
      getter level : Int32
      getter? ordered : Bool
      getter number : Int32
      getter alt : String
      getter width_px : Float64?
      getter align : Symbol
      getter lang : String?

      def initialize(@kind : Symbol, @text : String = "", @level : Int32 = 0,
                     @ordered : Bool = false, @number : Int32 = 0,
                     @alt : String = "", @width_px : Float64? = nil,
                     @align : Symbol = :left, @lang : String? = nil)
      end
    end

    getter source : String

    # Link click interceptor for a markdown viewer: receives the RAW
    # markdown target (url or relative path). Nil = the default —
    # http(s) through the browser, anything else resolved against
    # #base_dir and opened by the OS double-click handler.
    property on_link : (String ->)?

    # Root relative image paths resolve against (nil = paths stay as
    # written — cwd-relative).
    # Page background behind the rendered blocks (nil = the theme's
    # page: white on light themes, the dark canvas on dark ones; an
    # explicit color always wins).
    property background : Color32?

    def initialize(@source : String, base_dir : String? = nil,
                   id : String? = nil, pad_x : Float64 = DEFAULT_PAD_X,
                   @background : Color32? = nil)
      @base_dir = base_dir
      @id_name = id
      @pad_x = pad_x
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike
    end

    def inspector_label : String?
      line = @source.each_line.find { |l| !l.blank? }
      line.try &.strip
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)

      # Horizontal reading padding: the text never touches the window
      # edges (10px each side, overridable per widget).
      origin = ui.cursor
      width = ui.available_width
      # Themed page background, reserved up front and back-patched
      # once the content extent is known (Painter#set) so it lands
      # UNDER every block command.
      bg = @background || (style.visuals.dark ? PAGE_BG_DARK : PAGE_BG)
      bg_index = ui.painter.add_noop
      body = ui.child_ui(
        Rect.from_min_size(Pos2.new(origin.x + @pad_x, origin.y),
          Vec2.new({width - @pad_x * 2.0, 1.0}.max, 1e6)), id)
      # The engine walk: the cached Renderer dispatches every emitted
      # tag to its handler on the widget currently rendering (the
      # renderer is cached per SOURCE, the handlers need this frame's
      # #on_link/#base_dir — see @@current).
      renderer, rt = Markdown.renderer_cached(@source)
      @@current = self
      begin
        Markdown.nodes_cached(@source).each do |node|
          renderer.render(node, body, ui.ctx, rt)
        end
      ensure
        @@current = nil
      end

      ui.min_rect = ui.min_rect.union(body.min_rect)
      ui.cursor = Pos2.new(origin.x, body.cursor.y)
      if bg_index
        ui.painter.set(bg_index, RectCmd.new(
          clip: ui.clip,
          rect: Rect.from_min_size(origin,
            Vec2.new(width, body.min_rect.bottom - origin.y)),
          rounding: 0.0, fill: bg, stroke_color: nil, stroke_width: 0.0))
      end
      ui.interact(body.min_rect, id, Sense.none)
    end

    # --- parsing -------------------------------------------------------

    # The widget is recreated every frame (`Ui#markdown` builds a fresh
    # `Markdown` per draw), so the block model and the highlight
    # tokens cache on the CLASS, keyed by source / {lang, code}. Bounds
    # are coarse (clear-all past N entries): typical documents hold a
    # handful of blocks, and a clear only costs one re-parse.
    PARSE_CACHE = {} of String => Array(Block)
    TOKEN_CACHE = {} of String => Array(Tuple(String?, String))?

    def self.parse_cached(source : String) : Array(Block)
      if (cached = PARSE_CACHE[source]?)
        cached
      else
        PARSE_CACHE.clear if PARSE_CACHE.size >= 32
        PARSE_CACHE[source] = parse(source)
      end
    end

    # Fence langs that mean "no highlighting, please" — autodetecting
    # prose would paint false colors over what the author wrote as
    # verbatim text.
    PLAIN_LANGS = {"text", "plain", "plaintext", "txt", "none"}

    # Highlight tokens for a code block: the named language when
    # registered, otherwise relevance autodetect (a missing info
    # string or a language the highlighter doesn't ship). Explicit
    # plain langs and autodetect misses render unstyled.
    def self.tokens_cached(code : String, lang : String?) : Array(Tuple(String?, String))?
      return nil if lang && PLAIN_LANGS.includes?(lang)
      key = "#{lang || "\u{0}auto"}\u{1}#{code}"
      if (cached = TOKEN_CACHE[key]?)
        cached
      else
        TOKEN_CACHE.clear if TOKEN_CACHE.size >= 128
        tokens = Highlight.tokens(code, lang)
        # Unknown named language → try autodetect over the same text.
        if tokens.nil?
          tokens = Highlight.tokens(code, nil)
          # All-unscoped output (autodetect picked plaintext) is
          # indistinguishable from no highlighting — store nil so the
          # renderer takes its plain path.
          tokens = nil if tokens && tokens.all? { |scope, _| scope.nil? }
        end
        TOKEN_CACHE[key] = tokens
        tokens
      end
    end

    # GitHub-style syntax palettes (light / dark), keyed by the
    # highlighter's scope. Absent scopes (operator, punctuation —
    # GitHub paints those plain too) fall back to the text color.
    HL_LIGHT = {
      "keyword"              => Color32.rgba(0xCF, 0x22, 0x2E, 255),
      "literal"              => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "string"               => Color32.rgba(0x0A, 0x30, 0x69, 255),
      "regexp"               => Color32.rgba(0x0A, 0x30, 0x69, 255),
      "comment"              => Color32.rgba(0x59, 0x63, 0x6E, 255),
      "doctag"               => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "meta"                 => Color32.rgba(0xCF, 0x22, 0x2E, 255),
      "section"              => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "name"                 => Color32.rgba(0x11, 0x63, 0x29, 255),
      "tag"                  => Color32.rgba(0x11, 0x63, 0x29, 255),
      "attr"                 => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "attribute"            => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "symbol"               => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "bullet"               => Color32.rgba(0x95, 0x38, 0x00, 255),
      "variable"             => Color32.rgba(0x95, 0x38, 0x00, 255),
      "variable.language"    => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "variable.constant"    => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "title.function"       => Color32.rgba(0x82, 0x50, 0xDF, 255),
      "title.function.invoke" => Color32.rgba(0x82, 0x50, 0xDF, 255),
      "title.class"          => Color32.rgba(0x95, 0x38, 0x00, 255),
      "title.class.inherited" => Color32.rgba(0x95, 0x38, 0x00, 255),
      "title"                => Color32.rgba(0x95, 0x38, 0x00, 255),
      "type"                 => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "built_in"             => Color32.rgba(0x82, 0x50, 0xDF, 255),
      "number"               => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "params"               => Color32.rgba(0x95, 0x38, 0x00, 255),
      "property"             => Color32.rgba(0x05, 0x50, 0xAE, 255),
      "selector-tag"         => Color32.rgba(0x11, 0x63, 0x29, 255),
      "selector-id"          => Color32.rgba(0x82, 0x50, 0xDF, 255),
      "selector-class"       => Color32.rgba(0x82, 0x50, 0xDF, 255),
      "selector-attr"        => Color32.rgba(0x82, 0x50, 0xDF, 255),
      "selector-pseudo"      => Color32.rgba(0x82, 0x50, 0xDF, 255),
      "addition"             => Color32.rgba(0x11, 0x63, 0x29, 255),
      "deletion"             => Color32.rgba(0x82, 0x50, 0xDF, 255),
    } of String => Color32

    HL_DARK = {
      "keyword"              => Color32.rgba(0xFF, 0x7B, 0x72, 255),
      "literal"              => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "string"               => Color32.rgba(0xA5, 0xD6, 0xFF, 255),
      "regexp"               => Color32.rgba(0xA5, 0xD6, 0xFF, 255),
      "comment"              => Color32.rgba(0x8B, 0x94, 0x9E, 255),
      "doctag"               => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "meta"                 => Color32.rgba(0xFF, 0x7B, 0x72, 255),
      "section"              => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "name"                 => Color32.rgba(0x7E, 0xE7, 0x87, 255),
      "tag"                  => Color32.rgba(0x7E, 0xE7, 0x87, 255),
      "attr"                 => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "attribute"            => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "symbol"               => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "bullet"               => Color32.rgba(0xFF, 0xA6, 0x57, 255),
      "variable"             => Color32.rgba(0xFF, 0xA6, 0x57, 255),
      "variable.language"    => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "variable.constant"    => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "title.function"       => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
      "title.function.invoke" => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
      "title.class"          => Color32.rgba(0xFF, 0xA6, 0x57, 255),
      "title.class.inherited" => Color32.rgba(0xFF, 0xA6, 0x57, 255),
      "title"                => Color32.rgba(0xFF, 0xA6, 0x57, 255),
      "type"                 => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "built_in"             => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
      "number"               => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "params"               => Color32.rgba(0xFF, 0xA6, 0x57, 255),
      "property"             => Color32.rgba(0x79, 0xC0, 0xFF, 255),
      "selector-tag"         => Color32.rgba(0x7E, 0xE7, 0x87, 255),
      "selector-id"          => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
      "selector-class"       => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
      "selector-attr"        => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
      "selector-pseudo"      => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
      "addition"             => Color32.rgba(0x7E, 0xE7, 0x87, 255),
      "deletion"             => Color32.rgba(0xD2, 0xA8, 0xFF, 255),
    } of String => Color32

    # Palette lookup for a token scope: exact match first, then the
    # scope's first dotted segment (e.g. `title.function.invoke`
    # resolves through `title` when unmapped). nil → plain text color.
    def self.hl_color(scope : String?, dark : Bool) : Color32?
      return nil if scope.nil?
      return nil if scope.starts_with?("language-") # sublanguage wrapper
      table = dark ? HL_DARK : HL_LIGHT
      table[scope]? || table[scope.split('.').first]?
    end

    # Block model of a markdown source. Pure string surgery — the
    # rendering side never re-reads the source.
    def self.parse(source : String) : Array(Block)
      blocks = [] of Block
      lines = source.each_line.map(&.chomp('\r')).to_a
      paragraph = [] of String

      flush_paragraph = ->{
        unless paragraph.empty?
          blocks << Block.new(:paragraph, paragraph.join(" "))
          paragraph.clear
        end
      }

      i = 0
      while i < lines.size
        line = lines[i]
        stripped = line.strip

        if stripped.empty?
          flush_paragraph.call
          i += 1
          next
        end

        # Fenced code block: ``` (or longer) … matching close. The info
        # string's first word names the language (downcased) for syntax
        # highlighting. Content is verbatim — no markup, no stripping
        # beyond the trailing newline.
        if stripped.starts_with?("```")
          flush_paragraph.call
          fence = stripped[/^`+/]
          info = stripped[fence.size..].strip
          lang = info.empty? ? nil : info.split(/\s+/).first.downcase
          code = [] of String
          i += 1
          while i < lines.size && !lines[i].strip.starts_with?(fence)
            code << lines[i]
            i += 1
          end
          i += 1 # past the closing fence (or EOF)
          blocks << Block.new(:code, code.join("\n"), lang: lang)
          next
        end

        if (m = stripped.match(/^(\#{1,6})\s+(.*)$/))
          flush_paragraph.call
          blocks << Block.new(:heading, m[2].strip, m[1].size)
          i += 1
          next
        end

        # Horizontal rule: 3+ of -, * or _ alone on the line.
        if stripped.matches?(/^(-{3,}|\*{3,}|_{3,})$/)
          flush_paragraph.call
          blocks << Block.new(:hr)
          i += 1
          next
        end

        # Blockquote: consecutive `>` lines, one level stripped; the
        # quoted text renders as one weak paragraph (multi-paragraph
        # quotes collapse into one — fine for v1).
        if stripped.starts_with?(">")
          flush_paragraph.call
          quoted = [] of String
          while i < lines.size && (q = lines[i].strip).starts_with?(">")
            quoted << q.sub(/^>\s?/, "")
            i += 1
          end
          blocks << Block.new(:quote, quoted.join(" "))
          next
        end

        # Standalone image: `![alt](url)` alone on the line (a block,
        # not prose — gets a real Image widget).
        if (m = stripped.match(/^!\[([^\]]*)\]\(([^)]+)\)$/))
          flush_paragraph.call
          blocks << Block.new(:image, m[2], alt: m[1])
          i += 1
          next
        end

        # Minimal HTML: `<p align=…>…<img …>…</p>` (README logos) and
        # a bare `<img …>` line — the img tag's src/width/alt and the
        # wrapping p's align drive the image block.
        if stripped.starts_with?("<p ") || stripped.starts_with?("<img")
          flush_paragraph.call
          html = lines[i].strip
          # a <p …> wrapper may span lines until </p>
          if stripped.starts_with?("<p") && !html.includes?("</p>")
            i += 1
            while i < lines.size
              html += " " + lines[i].strip
              break if lines[i].includes?("</p>")
              i += 1
            end
          end
          if (img = html.match(/<img\b([^>]*)>/))
            attrs = img[1]
            src = attrs[/\bsrc\s*=\s*"([^"]*)"/, 1]? ||
                  attrs[/\bsrc\s*=\s*'([^']*)'/, 1]?
            if src
              width = attrs[/\bwidth\s*=\s*"(\d+)/, 1]?.try(&.to_f)
              alt = attrs[/\balt\s*=\s*"([^"]*)"/, 1]? ||
                    attrs[/\balt\s*=\s*'([^']*)'/, 1]? || ""
              align = if html =~ /align\s*=\s*"?center/i
                        :center
                      elsif html =~ /align\s*=\s*"?right/i
                        :right
                      else
                        :left
                      end
              blocks << Block.new(:image, src, alt: alt,
                width_px: width, align: align)
            end
          end
          i += 1
          next
        end

        # GFM table: a `| a | b |` header followed by a `| --- | --- |`
        # separator row (and optional alignment colons, ignored — v1
        # left-aligns) and body rows.
        if stripped.starts_with?("|") && i + 1 < lines.size &&
           lines[i + 1].strip.match(/^\|?[\s:|-]+\|?$/) &&
           lines[i + 1].includes?("-")
          flush_paragraph.call
          rows = [split_table_row(stripped)]
          i += 2
          while i < lines.size && lines[i].strip.starts_with?("|")
            rows << split_table_row(lines[i].strip)
            i += 1
          end
          blocks << Block.new(:table,
            rows.map { |r| r.join("\x1F") }.join("\n"))
          next
        end

        # List items: `- `/`* `/`+ ` bullets or `1. `/`1) ` numbers.
        # LAZY CONTINUATION: plain lines following an item (until a
        # blank line — the next paragraph — or another block kind)
        # soft-wrap into that item's text, so the whole "paragraph"
        # of the item renders with the hanging indent. An indented
        # marker opens a nested level (every 2 leading spaces).
        if (m = stripped.match(/^([-*+]|(\d+)[.)])\s+(.*)$/))
          flush_paragraph.call
          while i < lines.size
            line = lines[i]
            cur = line.strip
            if cur.empty?
              break # blank line ends the list (next paragraph)
            elsif (item = cur.match(/^([-*+]|(\d+)[.)])\s+(.*)$/))
              level = {line[/^\s*/].size // 2, 0}.max
              ordered = !item[2]?.nil?
              number = ordered ? item[2].to_i : 0
              blocks << Block.new(:list_item, item[3], level, ordered, number)
              i += 1
            elsif (last = blocks.last?) && last.kind == :list_item &&
                  plain_text_line?(cur)
              last.text = last.text.empty? ? cur : "#{last.text} #{cur}"
              i += 1
            else
              break # another block kind takes over
            end
          end
          next
        end

        paragraph << stripped
        i += 1
      end
      flush_paragraph.call
      blocks
    end

    # `| a | b |` (leading/trailing pipes optional) → cells.
    private def self.split_table_row(line : String) : Array(String)
      cells = line.strip.sub(/^\|/, "").sub(/\|$/, "").split('|')
      cells.map(&.strip)
    end

    # A line that continues the current LIST ITEM (lazy continuation):
    # plain prose — not another block kind's opener.
    private def self.plain_text_line?(stripped : String) : Bool
      return false if stripped.starts_with?(/\A(#|```|>|\||!\[|<p |<img)/)
      return false if stripped.matches?(/^(-{3,}|\*{3,}|_{3,})$/)
      true
    end

    # --- markdown → html ----------------------------------------------

    # The HTML document of a source, cached like the block model (the
    # widget is rebuilt every frame; the string is an explicit,
    # testable artifact of the pipeline).
    HTML_CACHE = {} of String => String

    def self.to_html_cached(source : String) : String
      if (cached = HTML_CACHE[source]?)
        cached
      else
        HTML_CACHE.clear if HTML_CACHE.size >= 32
        HTML_CACHE[source] = to_html(source)
      end
    end

    # Blocks → HTML. Text content is escaped; inline markup becomes
    # tags (see #inline_html). Table cells keep their marker text —
    # TableTextRenderer measures cells through RichText's own marker
    # parse, so passing markers through preserves styled cells.
    def self.to_html(source : String) : String
      blocks = parse_cached(source)
      String.build do |io|
        i = 0
        while i < blocks.size
          b = blocks[i]
          if b.kind == :list_item
            # Consecutive items → nested <ul>/<ol> (level = indent/2).
            items = [] of Tuple(Int32, Bool, Int32, String)
            while i < blocks.size && blocks[i].kind == :list_item
              it = blocks[i]
              items << {it.level, it.ordered?, it.number, it.text}
              i += 1
            end
            emit_list(items, io)
            next
          end
          case b.kind
          when :heading
            io << "<h#{b.level}>" << inline_html(b.text) << "</h#{b.level}>\n"
          when :paragraph
            io << "<p>" << inline_html(b.text) << "</p>\n"
          when :code
            io << "<pre"
            io << " lang=\"" << escape_attr(b.lang.not_nil!) << "\"" if b.lang
            io << ">" << escape_html(b.text) << "</pre>\n"
          when :quote
            io << "<blockquote>" << inline_html(b.text) << "</blockquote>\n"
          when :hr
            io << "<hr/>\n"
          when :image
            io << "<img src=\"" << escape_attr(b.text) << "\""
            io << " alt=\"" << escape_attr(b.alt) << "\"" unless b.alt.empty?
            io << " width=\"#{b.width_px.not_nil!.to_i}\"" if b.width_px
            io << " align=\"#{b.align}\"" unless b.align == :left
            io << "/>\n"
          when :table
            rows = b.text.split('\n').map(&.split("\x1F"))
            io << "<table>\n"
            rows.each_with_index do |row, ri|
              io << "<tr>"
              row.each do |cell|
                tag = ri == 0 ? "th" : "td"
                io << "<" << tag << ">" << escape_html(cell)
                io << "</" << tag << ">"
              end
              io << "</tr>\n"
            end
            io << "</table>\n"
          end
          i += 1
        end
      end
    end

    # A run of list-item blocks → nested `<ul>/<ol>/<li>` markup. The
    # stack tracks the open lists' orderedness; an item's number rides
    # as `n=` (an `<ol>` mid-list may start at any number). Nested
    # lists open INSIDE the parent's `<li>` (HTML semantics).
    private def self.emit_list(items : Array(Tuple(Int32, Bool, Int32, String)),
                               io : String::Builder) : Nil
      stack = [] of Bool # orderedness per open <ul>/<ol>
      in_li = false     # an <li> open at the innermost level
      items.each do |level, ordered, number, text|
        while stack.size > level + 1 ||
              (stack.size == level + 1 && stack.last != ordered)
          io << "</li>" if in_li
          in_li = false
          io << (stack.pop ? "</ol>" : "</ul>")
          in_li = !stack.empty? # back inside the parent item, if any
        end
        while stack.size < level + 1
          stack << ordered
          io << (ordered ? "<ol>" : "<ul>")
          in_li = false # the list opened inside the parent's <li>
        end
        io << "</li>" if in_li
        io << "<li n=\"#{number}\">" << inline_html(text)
        in_li = true
      end
      until stack.empty?
        io << "</li>" if in_li
        io << (stack.pop ? "</ol>" : "</ul>")
        in_li = !stack.empty?
      end
      io << "\n"
    end

    # Text-content escaping for the generated HTML.
    private def self.escape_html(s : String) : String
      s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
    end

    # Attribute-value escaping: text escaping plus the quote.
    private def self.escape_attr(s : String) : String
      escape_html(s).gsub('"', "&quot;")
    end

    # byte classes for the inline scanner (RichText's mirror)
    private BACKSLASH = 0x5C_u8
    private BACKTICK  = 0x60_u8
    private STAR      = 0x2A_u8
    private TILDE     = 0x7E_u8
    private LBRACKET  = 0x5B_u8
    private RBRACKET  = 0x5D_u8
    private LPAREN    = 0x28_u8
    private RPAREN    = 0x29_u8
    private BANG      = 0x21_u8

    # Inline markup → tags, the exact grammar `RichText#styled_runs`
    # parses (so the round trip renders identically): `**bold**` →
    # `<strong>`, `*italic*` → `<em>`, `~~strike~~` → `<del>`,
    # `` `code` `` → `<code>` (literal content), `[t](u)` → `<a href>`
    # (literal label), `![alt](url)` → the plain alt text. Unclosed
    # markers render literally; backslash escapes the next marker.
    private def self.inline_html(src : String) : String
      String.build { |io| inline_html_into(io, src) }
    end

    private def self.inline_html_into(io : String::Builder,
                                      src : String) : Nil
      bytes = src.to_unsafe
      total = src.bytesize
      i = 0
      while i < total
        case bytes[i]
        when BACKSLASH
          nxt = i + 1 < total ? bytes[i + 1] : nil
          if nxt && nxt.in?(STAR, BACKTICK, TILDE, BACKSLASH, LBRACKET,
                           RBRACKET)
            io << nxt.unsafe_chr
            i += 2
          else
            io << "\\"
            i += 1
          end
        when BACKTICK
          if (close = src.byte_index('`', i + 1))
            io << "<code>"
            io << escape_html(src.byte_slice(i + 1, close - i - 1))
            io << "</code>"
            i = close + 1
          else
            io << "`"
            i += 1
          end
        when TILDE
          tildes = 1
          while i + tildes < total && bytes[i + tildes] == TILDE
            tildes += 1
          end
          if tildes >= 2 && (close = find_run_close(src, i + tildes, TILDE, 2))
            io << "<del>"
            inline_html_into(io, src.byte_slice(i + 2, close - i - 2))
            io << "</del>"
            i = close + 2
          else
            tildes.times { io << "~" }
            i += tildes
          end
        when STAR
          stars = 1
          while i + stars < total && bytes[i + stars] == STAR
            stars += 1
          end
          if (close = find_run_close(src, i + stars, STAR, stars))
            io << "<strong>" if stars >= 2
            io << "<em>" if stars.odd?
            inline_html_into(io, src.byte_slice(i + stars, close - i - stars))
            io << "</em>" if stars.odd?
            io << "</strong>" if stars >= 2
            i = close + stars
          else
            stars.times { io << "*" }
            i += stars
          end
        when BANG
          # Inline image in prose: a text galley can't embed pixels —
          # the alt text stands in (same as RichText's own parse).
          if i + 1 < total && bytes[i + 1] == LBRACKET &&
             (close_br = src.byte_index(']', i + 2)) &&
             close_br + 1 < total && bytes[close_br + 1] == LPAREN &&
             (close_par = src.byte_index(')', close_br + 2))
            io << escape_html(src.byte_slice(i + 2, close_br - i - 2))
            i = close_par + 1
          else
            io << "!"
            i += 1
          end
        when LBRACKET
          close_br = src.byte_index(']', i + 1)
          if close_br && close_br + 1 < total &&
             bytes[close_br + 1] == LPAREN &&
             (close_par = src.byte_index(')', close_br + 2))
            label = src.byte_slice(i + 1, close_br - i - 1)
            url = src.byte_slice(close_br + 2, close_par - close_br - 2)
            io << "<a href=\"" << escape_attr(url) << "\">"
            io << escape_html(label) << "</a>"
            i = close_par + 1
          else
            io << "["
            i += 1
          end
        else
          # Copy the whole run of ordinary bytes in one slice — the
          # common case (plain prose) must not allocate per byte.
          j = i + 1
          while j < total
            break if bytes[j].in?(BACKSLASH, BACKTICK, STAR, TILDE,
                                  LBRACKET, BANG)
            j += 1
          end
          io << escape_html(src.byte_slice(i, j - i))
          i = j
        end
      end
    end

    # Closing marker for a run-delimited emphasis — RichText's twin
    # (both scanners must agree on where emphasis ends).
    private def self.find_run_close(src : String, from : Int32,
                                    byte : UInt8, min : Int32) : Int32?
      bytes = src.to_unsafe
      i = from
      while i < src.bytesize
        if bytes[i] == byte
          run = 1
          while i + run < src.bytesize && bytes[i + run] == byte
            run += 1
          end
          bs = 0
          j = i - 1
          while j >= 0 && bytes[j] == BACKSLASH
            bs += 1
            j -= 1
          end
          return i if run >= min && bs.even?
          i += run
        else
          i += 1
        end
      end
      nil
    end

    # --- html → nodes → engine ----------------------------------------

    # The parsed fragment, cached per source (the parse is pure; the
    # widget is rebuilt every frame).
    NODE_CACHE = {} of String => Array(Exml::Node)

    def self.nodes_cached(source : String) : Array(Exml::Node)
      if (cached = NODE_CACHE[source]?)
        cached
      else
        NODE_CACHE.clear if NODE_CACHE.size >= 32
        NODE_CACHE[source] = Exml.parse_fragment(to_html_cached(source))
      end
    end

    # Every tag #to_html emits — the markdown renderer's vocabulary,
    # registered as custom elements. The inline names (strong/em/
    # del/code/a) and the table structure (tr/th/td) never render
    # standalone: the block handlers walk them as content.
    TAGS = {"h1", "h2", "h3", "h4", "h5", "h6", "p", "pre", "blockquote",
            "ul", "ol", "li", "hr", "img", "table", "tr", "th", "td",
            "strong", "em", "del", "code", "a"}

    # One Renderer per SOURCE, cached: its cull bookkeeping is keyed
    # by node path, and one source is always one tree — two widgets
    # showing the same document may share the entry safely.
    RENDERER_CACHE = {} of String => Tuple(Exml::Renderer, Exml::Runtime)

    # The widget currently rendering. The tag handlers are closures on
    # the per-source cached renderer, but need the LIVE widget's state
    # (#on_link, #base_dir) — the UI renders on one thread, and #ui
    # sets the pointer around the walk.
    @@current : Markdown?

    def self.renderer_cached(source : String) : Tuple(Exml::Renderer, Exml::Runtime)
      if (cached = RENDERER_CACHE[source]?)
        cached
      else
        RENDERER_CACHE.clear if RENDERER_CACHE.size >= 16
        renderer = Exml::Renderer.new
        TAGS.each do |tag|
          renderer.on(tag) do |node, ui, _ctx, _rt, _r|
            @@current.not_nil!.render_tag(node, ui)
          end
        end
        entry = {renderer, Exml::Runtime.new}
        RENDERER_CACHE[source] = entry
        entry
      end
    end

    # The engine dispatch: a custom element named after an emitted
    # tag lands here, on the widget that is rendering this frame.
    def render_tag(node : Exml::Node, ui : Ui) : Nil
      style = ui.style
      case node.name
      when "p", "li" then ui.add(inline_label(node.children, style))
      when "h1", "h2", "h3", "h4", "h5", "h6"
        render_heading(node, ui, style)
      when "pre" then render_code_node(node, ui, style)
      when "blockquote" then render_quote(node, ui, style)
      when "ul", "ol" then render_list(node, ui, style)
      when "hr" then render_hr(ui, style)
      when "img" then render_image_node(node, ui, style)
      when "table" then render_table(node, ui, style)
      end
    end

    # --- inline html nodes → rich runs --------------------------------

    # The flattened text of inline nodes (what the runs spell out —
    # the selection/copy payload, like RichLabel's own parse).
    def self.plain_text(nodes : Array(Exml::Node)) : String
      String.build do |io|
        nodes.each do |n|
          if n.name == "#text"
            io << (n.attrs["text"]? || "")
          else
            io << plain_text(n.children)
          end
        end
      end
    end

    # Inline HTML nodes → TextRuns + LinkSpans, the same shapes
    # `RichText#styled_runs` produces from markers: `<code>` is the
    # 0.9375em monospace chip run, `<a>` the hyperlink-colored
    # underlined run plus its span over the flattened text.
    def self.inline_runs(nodes : Array(Exml::Node), size : Float64,
                         color : Color32, bold : Bool, italic : Bool,
                         strike : Bool, link_color : Color32,
                         runs : Array(TextRun),
                         links : Array(RichText::LinkSpan)) : Nil
      nodes.each do |n|
        case n.name
        when "#text"
          t = n.attrs["text"]? || ""
          unless t.empty?
            runs << TextRun.new(t, size, color, false, nil, bold,
              italic, strike)
          end
        when "strong"
          inline_runs(n.children, size, color, true, italic, strike,
            link_color, runs, links)
        when "em"
          inline_runs(n.children, size, color, bold, true, strike,
            link_color, runs, links)
        when "del"
          inline_runs(n.children, size, color, bold, italic, true,
            link_color, runs, links)
        when "code"
          t = plain_text(n.children)
          unless t.empty?
            runs << TextRun.new(t, size * 0.9375, color, false,
              "monospace", bold, italic, strike)
          end
        when "a"
          label = plain_text(n.children)
          unless label.empty?
            from = runs.sum(&.text.size)
            runs << TextRun.new(label, size, link_color, true, nil,
              bold, italic, strike)
            links << RichText::LinkSpan.new(from, from + label.size,
              n.attrs["href"]? || "")
          end
        end
      end
    end

    # A wrapped body-text RichLabel from a node's inline children:
    # preset runs + link spans wired to this widget's link handler.
    # `size:`/`color:`/`bold:` are the base style (headings scale and
    # go bold, quotes fade), layered under the inline tags like
    # RichText's base style.
    private def inline_label(nodes : Array(Exml::Node), style : Style,
                             lh : Float64? = BODY_LINE_H,
                             size : Float64? = nil,
                             color : Color32? = nil,
                             bold : Bool = false) : RichLabel
      runs = [] of TextRun
      links = [] of RichText::LinkSpan
      Markdown.inline_runs(nodes, size || style.font_size,
        color || style.visuals.text_color, bold, false, false,
        style.visuals.hyperlink_color, runs, links)
      label = RichLabel.new(RichText.new(Markdown.plain_text(nodes)),
        wrap: true, line_height: lh)
      label.preset = {runs, links}
      label.link_handler = ->open_link(String)
      label
    end

    # Every plain rich-text label goes through here (table cells keep
    # the marker path — TableTextRenderer measures them the same way).
    private def text_label(rich : RichText, wrap : Bool? = true,
                           lh : Float64? = BODY_LINE_H) : RichLabel
      label = RichLabel.new(rich, wrap: wrap, line_height: lh)
      label.link_handler = ->open_link(String)
      label
    end

    # Link activation: the app's #on_link wins; the default routes
    # http(s) to the browser and resolves everything else against
    # #base_dir for the OS "open with default application" handler —
    # relative doc links (`[WATCH DEMO](DEMO.md)`) land on real files.
    private def open_link(target : String) : Nil
      if (handler = @on_link)
        handler.call(target)
      elsif target.starts_with?("http://") || target.starts_with?("https://")
        Hyperlink.open_url(target)
      else
        path = @base_dir ? File.expand_path(target, @base_dir.not_nil!)
                         : File.expand_path(target)
        SystemPorts::FileOpen.show(path)
      end
    end

    # --- tag handlers (standard widgets, GitHub look) -----------------

    private def render_heading(node : Exml::Node, ui : Ui,
                               style : Style) : Nil
      level = node.name.lchop('h').to_i? || 1
      scale = HEADING_SCALES[level - 1]? || 1.0
      # H1 carries 20px of top padding — section separation.
      ui.cursor = Pos2.new(ui.cursor.x, ui.cursor.y + 20.0) if level == 1
      top = ui.cursor
      ui.add(inline_label(node.children, style, lh: HEADING_LINE_H,
        size: style.font_size * scale, bold: true))
      # GitHub-style: H1/H2 carry a rule under the heading text.
      if level <= 2
        y = ui.cursor.y - style.spacing.item_spacing.y
        ui.painter.line(Pos2.new(top.x, y),
          Pos2.new({top.x + ui.available_width, top.x}.max, y), 1.0,
          style.visuals.fade_color(style.visuals.text_color, 0.45))
      end
    end

    # A horizontal rule with at least HR_PAD of breathing room above
    # and below the line (on top of the regular item spacing).
    private def render_hr(ui : Ui, style : Style) : Nil
      top = ui.cursor
      y = top.y + HR_PAD
      rect = ui.allocate_at_least(
        Vec2.new(ui.available_width, HR_PAD * 2.0 + 1.0))
      y = {y, rect.top + HR_PAD}.max
      ui.painter.line(Pos2.new(rect.left, y),
        Pos2.new(rect.right, y), 1.0,
        style.visuals.dark ? HR_COLOR_DARK : HR_COLOR)
    end

    # `<ul>/<ol>`: one hanging-indent row per `<li>` (the bullet in
    # its own left column, wrapped lines aligned to the text column),
    # nested lists one indent deeper — the flat block model's levels
    # map 1:1 to the node nesting.
    private def render_list(node : Exml::Node, ui : Ui, style : Style,
                            depth : Int32 = 0) : Nil
      ordered = node.name == "ol"
      node.children.each do |child|
        next unless child.name == "li"
        number = child.attrs["n"]?.try(&.to_i) || 0
        render_list_item(ui, child, style, depth, ordered, number)
        child.children.each do |sub|
          if sub.name == "ul" || sub.name == "ol"
            render_list(sub, ui, style, depth + 1)
          end
        end
      end
    end

    private def render_list_item(ui : Ui, item : Exml::Node, style : Style,
                                 level : Int32, ordered : Bool,
                                 number : Int32) : Nil
      marker = ordered ? "#{number}." : "•"
      # The item's own block indent + one step per nesting level.
      indent = style.spacing.indent * 0.5 +
               level * style.spacing.indent * 0.75
      fonts = ui.ctx.fonts_for(style.font_family)
      marker_w = fonts.measure(marker, style.font_size).x
      bullet_w = marker_w + style.spacing.item_spacing.x * 2.0

      top = Pos2.new(ui.cursor.x + indent, ui.cursor.y)
      avail = {ui.available_width - indent, bullet_w + 20.0}.max

      bullet = ui.child_ui(Rect.from_min_size(top,
        Vec2.new(bullet_w, 1e6)))
      bullet.add(Label.new(marker, userselect: false))

      text = ui.child_ui(Rect.from_min_size(
        Pos2.new(top.x + bullet_w, top.y),
        Vec2.new({avail - bullet_w, 20.0}.max, 1e6)))
      text.add(inline_label(item.children, style))

      bottom = {bullet.min_rect.bottom, text.min_rect.bottom}.max
      ui.min_rect = ui.min_rect.union(
        Rect.new(top, Pos2.new({top.x + avail, top.x}.max, bottom)))
      ui.cursor = Pos2.new(ui.cursor.x,
        bottom + style.spacing.item_spacing.y)
    end

    private def render_quote(node : Exml::Node, ui : Ui,
                             style : Style) : Nil
      indent = style.spacing.indent * 0.75
      top = ui.cursor
      inner = ui.child_ui(Rect.from_min_size(
        Pos2.new(top.x + indent, top.y),
        Vec2.new({ui.available_width - indent, 1.0}.max, 1e6)))
      inner.add(inline_label(node.children, style,
        color: style.visuals.fade_color(style.visuals.text_color, 0.6)))
      advance_past(ui, inner, top)
      # Accent bar down the quote's left edge.
      bottom = inner.min_rect.bottom - style.spacing.item_spacing.y
      ui.painter.line(Pos2.new(top.x + 2.0, top.y),
        Pos2.new(top.x + 2.0, {bottom, top.y}.max), 2.0,
        style.visuals.fade_color(style.visuals.text_color, 0.4))
    end

    # `<pre lang=…>`: a selectable monospace Label on a subtle rounded
    # rect. Syntax-highlighted when the fence named a language (or
    # autodetect scored one): one colored TextRun per highlight token,
    # baked as the Label's preset runs. No wrap: long lines stay on
    # one row, clipped like code editors.
    private def render_code_node(node : Exml::Node, ui : Ui,
                                 style : Style) : Nil
      render_code(ui, Markdown.plain_text(node.children),
        node.attrs["lang"]?, style)
    end

    private def render_code(ui : Ui, code : String, lang : String?,
                            style : Style) : Nil
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ui.ctx.fonts_for(family, bold, italic) }
      fonts = ui.ctx.fonts_for(style.font_family)
      rich = RichText.new(code).code
      # 14px monospace at the default 16px body (0.875 — fenced blocks
      # stay a notch smaller than the now-15px inline chips).
      rich = rich.size(style.font_size * 0.875)
      preset =
        if (tokens = Markdown.tokens_cached(code, lang))
          base = style.visuals.text_color
          dark = style.visuals.dark
          tokens.map { |scope, text|
            TextRun.new(text, style.font_size * 0.875,
              Markdown.hl_color(scope, dark) || base,
              family: "monospace")
          }
        end
      galley = fonts.layout(
        preset || rich.runs(style.font_size, style.visuals.text_color),
        nil, resolve)

      pad = 8.0
      size = Vec2.new(galley.size.x + pad * 2.0, galley.size.y + pad * 2.0)
      rect = ui.allocate_at_least(size)
      ui.painter.rect(rect, 4.0,
        style.visuals.dark ? CODE_BG_DARK : CODE_BG)
      inner = ui.child_ui(Rect.from_min_size(
        Pos2.new(rect.left + pad, rect.top + pad), galley.size))
      inner.add(Label.new(rich, wrap: false, preset_runs: preset))
    end

    # `<table>`: delegated to TableTextRenderer (min/max column
    # auto-layout, wrapped cells, full borders); header row bold.
    # Cells keep their marker text — the factory's RichLabels parse
    # it, the same path the block renderer used.
    private def render_table(node : Exml::Node, ui : Ui,
                             style : Style) : Nil
      rows = [] of Array(String)
      node.children.each do |tr|
        next unless tr.name == "tr"
        row = [] of String
        tr.children.each do |cell|
          if cell.name == "td" || cell.name == "th"
            row << Markdown.plain_text(cell.children)
          end
        end
        rows << row
      end
      TableTextRenderer.new(rows).render(ui, style, BODY_LINE_H) do |text, header|
        rich = RichText.new(text)
        rich.bold if header
        text_label(rich)
      end
    end

    # `<img>`: the texture loads through `Context#load_image` (cached
    # per path), sized by a header-only probe (`Context#image_size` —
    # the ImageCodec seam) and scaled DOWN to the available width
    # (never up — small icons keep their pixels). An explicit width
    # clamps further; `align` shifts the block. An unloadable/remote
    # image degrades to a weak alt label.
    private def render_image_node(node : Exml::Node, ui : Ui,
                                  style : Style) : Nil
      align = case node.attrs["align"]?
              when "center" then :center
              when "right"  then :right
              else               :left
              end
      render_image(ui, node.attrs["src"]? || "", style,
        node.attrs["alt"]? || "",
        node.attrs["width"]?.try(&.to_f?), align)
    end

    private def render_image(ui : Ui, path : String, style : Style,
                             alt : String, width_px : Float64?,
                             align : Symbol) : Nil
      path = resolve_image_path(path)
      texture = ui.ctx.load_image(path)
      avail = ui.available_width
      if texture > 0 && (sz = ui.ctx.image_size(path)) &&
         sz.x > 0 && sz.y > 0
        draw_w = sz.x
        # explicit <img width=…> clamps; then fit the available width
        # (never upscale)
        if (want = width_px) && want < draw_w
          draw_w = want
        end
        draw_w = {draw_w, avail}.min
        scale = draw_w / sz.x
        size = Vec2.new(sz.x * scale, sz.y * scale)
        x = case align
            when :center then ui.cursor.x + {(avail - size.x) / 2.0, 0.0}.max
            when :right  then ui.cursor.x + {avail - size.x, 0.0}.max
            else              ui.cursor.x
            end
        top = Pos2.new(x, ui.cursor.y)
        cell = ui.child_ui(Rect.from_min_size(top, size))
        cell.add(Image.new(texture, size))
        bottom = {cell.min_rect.bottom, top.y + size.y}.max
        ui.min_rect = ui.min_rect.union(
          Rect.new(ui.cursor, Pos2.new({top.x + size.x, ui.cursor.x}.max, bottom)))
        ui.cursor = Pos2.new(ui.cursor.x,
          bottom + style.spacing.item_spacing.y)
      else
        alt = alt.empty? ? path : alt
        ui.add(RichLabel.new(
          RichText.new("[image: #{alt}]").weak(style.visuals)))
      end
    end

    # Advance the parent cursor past a manually-built child region:
    # a horizontal row never advances cursor.y (`Layout` moves the
    # cursor along its direction only), so the row's EXTENT is
    # `min_rect.bottom` (allocate_space grows it down by row height) —
    # `cursor.y` would stack every item on one line.
    private def advance_past(ui : Ui, child : Ui, top : Pos2) : Nil
      ui.min_rect = ui.min_rect.union(child.min_rect)
      ui.cursor = Pos2.new(top.x,
        child.min_rect.bottom + ui.style.spacing.item_spacing.y)
    end

    # Relative image URLs resolve against #base_dir; absolute paths
    # and remote URLs (http/https — no fetcher) pass through as-is.
    private def resolve_image_path(url : String) : String
      if (base = @base_dir) && !url.starts_with?("/") &&
         !url.starts_with?("http://") && !url.starts_with?("https://")
        File.expand_path(url, base)
      else
        url
      end
    end
  end
end
