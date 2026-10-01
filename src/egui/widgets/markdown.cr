# Markdown widget — rendered markdown, built as a COMBINATION of the
# existing widgets (the user-facing design: RichLabel for inline
# styles, Separator for rules, plain rects for code blocks) rather
# than one monolithic painter.
#
# Supported blocks: ATX headings (`#`…`######`), paragraphs (soft-wrap
# lines joined), fenced code blocks (``` — rendered as a monospace
# block on a subtle background, NO syntax highlighting), blockquotes
# (`>`, weak text + accent bar), bullet/ordered lists, horizontal
# rules. Inline markup inside every text block goes through
# RichLabel: `**bold**`, `*italic*`, `***both***`, `` `code` `` and
# `[label](url)` links.
#
# Parsing is pure (`Markdown.parse` — no Context) so specs can test
# the block model headless; `#ui` only lays blocks out.

module Egui
  class Markdown
    include Widget

    # HTML-ish heading scale over the style's font size; all bold.
    HEADING_SCALES = {1.6, 1.35, 1.15, 1.0, 0.9, 0.85}

    # One parsed block. `text` carries the STRIPPED content (markers
    # removed); heading `level` is 1-6, list items keep their number
    # (`ordered` false → bullet), an image block's text is the URL and
    # `alt` its alt text.
    class Block
      getter kind : Symbol
      getter text : String
      getter level : Int32
      getter? ordered : Bool
      getter number : Int32
      getter alt : String

      def initialize(@kind : Symbol, @text : String = "", @level : Int32 = 0,
                     @ordered : Bool = false, @number : Int32 = 0,
                     @alt : String = "")
      end
    end

    getter source : String

    # Root relative image paths resolve against (nil = paths stay as
    # written — cwd-relative).
    def initialize(@source : String, base_dir : String? = nil,
                   id : String? = nil)
      @base_dir = base_dir
      @id_name = id
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

      origin = ui.cursor
      width = ui.available_width
      body = ui.child_ui(
        Rect.from_min_size(origin, Vec2.new({width, 1.0}.max, 1e6)), id)
      Markdown.parse(@source).each { |b| render_block(body, b, style) }

      ui.min_rect = ui.min_rect.union(body.min_rect)
      ui.cursor = Pos2.new(origin.x, body.cursor.y)
      ui.interact(body.min_rect, id, Sense.none)
    end

    # --- parsing -------------------------------------------------------

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

        # Fenced code block: ``` (or longer) … matching close. The
        # info string after the opening fence is ignored (no syntax
        # highlighting). Content is verbatim — no markup, no stripping
        # beyond the trailing newline.
        if stripped.starts_with?("```")
          flush_paragraph.call
          fence = stripped[/^`+/]
          code = [] of String
          i += 1
          while i < lines.size && !lines[i].strip.starts_with?(fence)
            code << lines[i]
            i += 1
          end
          i += 1 # past the closing fence (or EOF)
          blocks << Block.new(:code, code.join("\n"))
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

        # List items: `- `/`* `/`+ ` bullets or `1. `/`1) ` numbers.
        # Flat (nesting by indentation is not tracked — v1); a blank
        # line or any other block ends the list.
        if (m = stripped.match(/^([-*+]|(\d+)[.)])\s+(.*)$/))
          flush_paragraph.call
          while i < lines.size &&
                (item = lines[i].strip.match(/^([-*+]|(\d+)[.)])\s+(.*)$/))
            ordered = !item[2]?.nil?
            number = ordered ? item[2].to_i : 0
            blocks << Block.new(:list_item, item[3], 0, ordered, number)
            i += 1
          end
          next
        end

        paragraph << stripped
        i += 1
      end
      flush_paragraph.call
      blocks
    end

    # --- rendering -----------------------------------------------------

    private def render_block(ui : Ui, block : Block, style : Style) : Nil
      case block.kind
      when :heading
        scale = HEADING_SCALES[block.level - 1]? || 1.0
        ui.add(RichLabel.new(
          RichText.new(block.text).size(style.font_size * scale).bold))
      when :paragraph
        ui.add(RichLabel.new(block.text))
      when :hr
        ui.add(Separator.new)
      when :list_item
        render_list_item(ui, block, style)
      when :quote
        render_quote(ui, block, style)
      when :code
        render_code(ui, block, style)
      when :image
        render_image(ui, block, style)
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

    private def render_list_item(ui : Ui, block : Block, style : Style) : Nil
      marker = block.ordered? ? "#{block.number}." : "•"
      top = ui.cursor
      row = ui.child_ui(Rect.from_min_size(top,
        Vec2.new(ui.available_width, 1e6)), layout: Layout.left_to_right)
      row.add(Label.new(marker, userselect: false))
      row.add(RichLabel.new(block.text, wrap: true))
      advance_past(ui, row, top)
    end

    private def render_quote(ui : Ui, block : Block, style : Style) : Nil
      indent = style.spacing.indent * 0.75
      top = ui.cursor
      inner = ui.child_ui(Rect.from_min_size(
        Pos2.new(top.x + indent, top.y),
        Vec2.new({ui.available_width - indent, 1.0}.max, 1e6)))
      inner.add(RichLabel.new(
        RichText.new(block.text).weak(style.visuals)))
      advance_past(ui, inner, top)
      # Accent bar down the quote's left edge.
      bottom = inner.min_rect.bottom - style.spacing.item_spacing.y
      ui.painter.line(Pos2.new(top.x + 2.0, top.y),
        Pos2.new(top.x + 2.0, {bottom, top.y}.max), 2.0,
        style.visuals.fade_color(style.visuals.text_color, 0.4))
    end

    # Code block: a selectable monospace Label (verbatim text — no
    # markup parsing, no highlighting) on a subtle rounded rect. No
    # wrap: long lines stay on one row, clipped like code editors.
    private def render_code(ui : Ui, block : Block, style : Style) : Nil
      resolve = ->(family : String?) { ui.ctx.fonts_for(family) }
      fonts = ui.ctx.fonts_for(style.font_family)
      rich = RichText.new(block.text).code
      galley = fonts.layout(
        rich.runs(style.font_size, style.visuals.text_color), nil, resolve)

      pad = 8.0
      size = Vec2.new(galley.size.x + pad * 2.0, galley.size.y + pad * 2.0)
      rect = ui.allocate_at_least(size)
      ui.painter.rect(rect, 4.0,
        style.visuals.fade_color(style.visuals.text_color, 0.12))
      inner = ui.child_ui(Rect.from_min_size(
        Pos2.new(rect.left + pad, rect.top + pad), galley.size))
      inner.add(Label.new(rich, wrap: false))
    end

    # Standalone image block: the texture loads through
    # `Context#load_image` (cached per path), sized by a header-only
    # probe (`TextureRegistry#image_size`) and scaled DOWN to the
    # available width (never up — small icons keep their pixels).
    # An unloadable/remote image degrades to a weak alt-text label.
    private def render_image(ui : Ui, block : Block, style : Style) : Nil
      path = resolve_image_path(block.text)
      texture = ui.ctx.load_image(path)
      if texture > 0 && (sz = ui.ctx.textures.image_size(path)) &&
         sz.x > 0 && sz.y > 0
        scale = {ui.available_width / sz.x, 1.0}.min
        ui.add(Image.new(texture, Vec2.new(sz.x * scale, sz.y * scale)))
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
