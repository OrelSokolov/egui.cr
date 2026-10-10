# Markdown widget — rendered markdown, built as a COMBINATION of the
# existing widgets (the user-facing design: RichLabel for inline
# styles, Separator for rules, plain rects for code blocks) rather
# than one monolithic painter.
#
# Supported blocks: ATX headings (`#`…`######`), paragraphs (soft-wrap
# lines joined), fenced code blocks (``` — monospace on a subtle
# background, SYNTAX HIGHLIGHTED through the highlight_cr port of
# highlight.js: the fence's info string names the language, a missing
# or unknown one falls back to relevance autodetect), blockquotes
# (`>`, weak text + accent bar), bullet/ordered lists, horizontal
# rules. Inline markup inside every text block goes through
# RichLabel: `**bold**`, `*italic*`, `***both***`, `` `code` `` and
# `[label](url)` links.
#
# Parsing is pure (`Markdown.parse` — no Context) so specs can test
# the block model headless; `#ui` only lays blocks out.

require "highlight_cr"

module Egui
  class Markdown
    include Widget

    # HTML-ish heading scale over the style's font size; all bold.
    # h1/h2 are GitHub's 2em/1.5em — 32/24px at the default 16px body.
    HEADING_SCALES = {2.0, 1.5, 1.15, 1.0, 0.9, 0.85}
    # Fenced-code background (non-inline blocks; the inline chip is
    # RichLabel::INLINE_CODE_BG).
    CODE_BG = Color32.rgba(0xF0, 0xF1, 0xF3, 255)
    # Horizontal rules carry at least this much breathing room above
    # and below the line.
    HR_PAD = 5.0
    # Horizontal rule stroke: soft gray, ~70% opacity.
    HR_COLOR = Color32.rgba(0xD1, 0xD9, 0xE0, 0xB3)
    # Default horizontal reading padding (the text never touches the
    # window edges); override per widget with `pad_x:`.
    DEFAULT_PAD_X = 10.0
    # Default page background — white, a reader page. nil via
    # `background: nil` disables it (transparent over the panel).
    DEFAULT_BG = Color32.rgba(255, 255, 255, 255)

    # One parsed block. `text` carries the STRIPPED content (markers
    # removed); heading `level` is 1-6, list items keep their number
    # (`ordered` false → bullet), an image block's text is the URL,
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
    # Page background behind the rendered blocks (nil = transparent).
    property background : Color32?

    def initialize(@source : String, base_dir : String? = nil,
                   id : String? = nil, pad_x : Float64 = DEFAULT_PAD_X,
                   @background : Color32? = DEFAULT_BG)
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
      # White page background, reserved up front and back-patched
      # once the content extent is known (Painter#set) so it lands
      # UNDER every block command. nil = no background.
      bg_index = ui.painter.add_noop if @background
      body = ui.child_ui(
        Rect.from_min_size(Pos2.new(origin.x + @pad_x, origin.y),
          Vec2.new({width - @pad_x * 2.0, 1.0}.max, 1e6)), id)
      Markdown.parse_cached(@source).each { |b| render_block(body, b, style) }

      ui.min_rect = ui.min_rect.union(body.min_rect)
      ui.cursor = Pos2.new(origin.x, body.cursor.y)
      if (bg = @background) && bg_index
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
    # `Markdown` per draw), so both the block model and the highlight
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

    # --- rendering -----------------------------------------------------

    private def render_block(ui : Ui, block : Block, style : Style) : Nil
      case block.kind
      when :heading
        scale = HEADING_SCALES[block.level - 1]? || 1.0
        # H1 carries 20px of top padding — section separation.
        ui.cursor = Pos2.new(ui.cursor.x, ui.cursor.y + 20.0) if block.level == 1
        top = ui.cursor
        ui.add(text_label(
          RichText.new(block.text).size(style.font_size * scale).bold))
        # GitHub-style: H1/H2 carry a rule under the heading text.
        if block.level <= 2
          y = ui.cursor.y - style.spacing.item_spacing.y
          ui.painter.line(Pos2.new(top.x, y),
            Pos2.new({top.x + ui.available_width, top.x}.max, y), 1.0,
            style.visuals.fade_color(style.visuals.text_color, 0.45))
        end
      when :paragraph
        ui.add(text_label(block.text))
      when :hr
        render_hr(ui, style)
      when :list_item
        render_list_item(ui, block, style)
      when :quote
        render_quote(ui, block, style)
      when :code
        render_code(ui, block, style)
      when :image
        render_image(ui, block, style)
      when :table
        render_table(ui, block, style)
      end
    end

    # Every text block goes through here: a RichLabel with this
    # widget's link handler wired in.
    private def text_label(text : String, wrap : Bool? = true) : RichLabel
      label = RichLabel.new(text, wrap: wrap)
      label.link_handler = ->open_link(String)
      label
    end

    private def text_label(rich : RichText, wrap : Bool? = true) : RichLabel
      label = RichLabel.new(rich, wrap: wrap)
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

    # A horizontal rule with at least HR_PAD of breathing room above
    # and below the line (on top of the regular item spacing).
    private def render_hr(ui : Ui, style : Style) : Nil
      top = ui.cursor
      y = top.y + HR_PAD
      rect = ui.allocate_at_least(
        Vec2.new(ui.available_width, HR_PAD * 2.0 + 1.0))
      y = {y, rect.top + HR_PAD}.max
      ui.painter.line(Pos2.new(rect.left, y),
        Pos2.new(rect.right, y), 1.0, HR_COLOR)
    end

    # A list item hangs: the bullet sits in its own left column, the
    # text in another — wrapped lines stay aligned to the text column
    # and never run under the bullet (hanging indent, GitHub-style).
    # The whole item is indented from the margin so lists read as a
    # block, not as loose lines.
    private def render_list_item(ui : Ui, block : Block, style : Style) : Nil
      marker = block.ordered? ? "#{block.number}." : "•"
      # The item's own block indent + one step per nesting level.
      indent = style.spacing.indent * 0.5 +
               block.level * style.spacing.indent * 0.75
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
      text.add(text_label(block.text, true))

      bottom = {bullet.min_rect.bottom, text.min_rect.bottom}.max
      ui.min_rect = ui.min_rect.union(
        Rect.new(top, Pos2.new({top.x + avail, top.x}.max, bottom)))
      ui.cursor = Pos2.new(ui.cursor.x,
        bottom + style.spacing.item_spacing.y)
    end

    private def render_quote(ui : Ui, block : Block, style : Style) : Nil
      indent = style.spacing.indent * 0.75
      top = ui.cursor
      inner = ui.child_ui(Rect.from_min_size(
        Pos2.new(top.x + indent, top.y),
        Vec2.new({ui.available_width - indent, 1.0}.max, 1e6)))
      inner.add(text_label(RichText.new(block.text).weak(style.visuals)))
      advance_past(ui, inner, top)
      # Accent bar down the quote's left edge.
      bottom = inner.min_rect.bottom - style.spacing.item_spacing.y
      ui.painter.line(Pos2.new(top.x + 2.0, top.y),
        Pos2.new(top.x + 2.0, {bottom, top.y}.max), 2.0,
        style.visuals.fade_color(style.visuals.text_color, 0.4))
    end

    # Code block: a selectable monospace Label on a subtle rounded
    # rect. Syntax-highlighted when the fence named a language (or
    # autodetect scored one): one colored TextRun per highlight token,
    # baked as the Label's preset runs. No wrap: long lines stay on
    # one row, clipped like code editors.
    private def render_code(ui : Ui, block : Block, style : Style) : Nil
      resolve = ->(family : String?, bold : Bool, italic : Bool) { ui.ctx.fonts_for(family, bold, italic) }
      fonts = ui.ctx.fonts_for(style.font_family)
      rich = RichText.new(block.text).code
      # 14px monospace at the default 16px body (0.875 — the same
      # ratio as inline code chips).
      rich = rich.size(style.font_size * 0.875)
      preset =
        if (tokens = Markdown.tokens_cached(block.text, block.lang))
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
      ui.painter.rect(rect, 4.0, CODE_BG)
      inner = ui.child_ui(Rect.from_min_size(
        Pos2.new(rect.left + pad, rect.top + pad), galley.size))
      inner.add(Label.new(rich, wrap: false, preset_runs: preset))
    end

    # GFM table: delegated to TableTextRenderer (min/max column
    # auto-layout, wrapped cells, full borders); header row bold.
    private def render_table(ui : Ui, block : Block, style : Style) : Nil
      rows = block.text.split('\n').map(&.split("\x1F"))
      TableTextRenderer.new(rows).render(ui, style) do |text, header|
        rich = RichText.new(text)
        rich.bold if header
        text_label(rich, true)
      end
    end

    # Standalone image block: the texture loads through
    # `Context#load_image` (cached per path), sized by a header-only
    # probe (`TextureRegistry#image_size`) and scaled DOWN to the
    # available width (never up — small icons keep their pixels).
    # An explicit `<img width=…>` clamps further; `align` shifts the
    # block. An unloadable/remote image degrades to a weak alt label.
    private def render_image(ui : Ui, block : Block, style : Style) : Nil
      path = resolve_image_path(block.text)
      texture = ui.ctx.load_image(path)
      avail = ui.available_width
      if texture > 0 && (sz = ui.ctx.textures.image_size(path)) &&
         sz.x > 0 && sz.y > 0
        draw_w = sz.x
        # explicit <img width=…> clamps; then fit the available width
        # (never upscale)
        if (want = block.width_px) && want < draw_w
          draw_w = want
        end
        draw_w = {draw_w, avail}.min
        scale = draw_w / sz.x
        size = Vec2.new(sz.x * scale, sz.y * scale)
        x = case block.align
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
        alt = block.alt.empty? ? block.text : block.alt
        ui.add(RichLabel.new(
          RichText.new("[image: #{alt}]").weak(style.visuals)))
      end
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
