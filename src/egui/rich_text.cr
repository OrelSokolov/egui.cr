# Port of egui_upstream/crates/egui/src/widget_text.rs (subset).
#
# `RichText` is a styled string: chainable size/color/underline
# builders. A widget turns it into `TextRun`s for `Fonts#layout`.
#
# The base style (`size`/`color`/`underline`/`bold`/`italic`/`code`)
# applies to the WHOLE string; `#styled_runs` additionally parses
# inline markdown markup — `**bold**`, `*italic*`, `***both***`,
# `` `code` `` and `[label](url)` links — into per-span runs layered
# over the base style. `#runs` (the historical single-run form) does
# not parse: plain `Label` must keep rendering its text verbatim.

module Egui
  class RichText
    getter text : String
    getter size : Float64?
    getter color : Color32?
    getter? underline : Bool
    getter? bold : Bool
    getter? italic : Bool
    getter? code : Bool
    getter? strikethrough : Bool

    def initialize(@text : String, @size : Float64? = nil,
                   @color : Color32? = nil, @underline : Bool = false,
                   @bold : Bool = false, @italic : Bool = false,
                   @code : Bool = false, @strikethrough : Bool = false)
    end

    def size(s : Float64) : RichText
      @size = s
      self
    end

    def color(c : Color32) : RichText
      @color = c
      self
    end

    def underline : RichText
      @underline = true
      self
    end

    # Line through the middle of the text (markdown `~~text~~`).
    def strikethrough : RichText
      @strikethrough = true
      self
    end

    # Base synthetic bold for the whole string (headings).
    def bold : RichText
      @bold = true
      self
    end

    # Base synthetic italic for the whole string.
    def italic : RichText
      @italic = true
      self
    end

    # Base monospace family for the whole string (code blocks).
    def code : RichText
      @code = true
      self
    end

    def heading(default_size : Float64) : RichText
      size(default_size * 1.25)
    end

    def small(default_size : Float64) : RichText
      size(default_size * 0.8)
    end

    def weak(visuals : Visuals) : RichText
      color(visuals.fade_color(visuals.text_color, 0.6))
    end

    def runs(default_size : Float64, default_color : Color32) : Array(TextRun)
      [TextRun.new(@text, @size || default_size,
        @color || default_color, @underline, @code ? "monospace" : nil,
        @bold, @italic, @strikethrough)]
    end

    # A link span parsed out of the markup: CHAR range within the
    # STRIPPED text (what the runs spell out — markers removed, spans
    # concatenated) plus the URL. `RichLabel` hit-tests pointer
    # positions against these ranges — char units, matching how the
    # galley flattens row text (multibyte glyphs count as one).
    struct LinkSpan
      getter from : Int32
      getter to : Int32
      getter url : String

      def initialize(@from, @to, @url)
      end
    end

    getter link_spans : Array(LinkSpan) = [] of LinkSpan

    # Parse inline markup into per-span runs over the base style:
    # `**bold**`, `*italic*`, `***both***`, `~~strike~~`, `` `code` ``
    # and `[label](url)` (hyperlink-colored + underlined). Unclosed
    # markers render literally; emphasis nests by recursion; code
    # spans are literal (no markup inside backticks); backslash
    # escapes the next marker character. `#link_spans` carries the
    # link ranges for the widget that laid the runs out.
    def styled_runs(default_size : Float64, default_color : Color32,
                    link_color : Color32) : Array(TextRun)
      runs = [] of TextRun
      @link_spans.clear
      parse_inline(@text, runs, @link_spans, @size || default_size,
        @color || default_color, @bold, @italic,
        @code ? "monospace" : nil, link_color)
      runs
    end

    # When no monospace stack is installed (`Context#mono_fonts` nil),
    # monospace runs draw in the SAME proportional font and inline
    # code stops reading as code — retint them weaker so the span
    # stays visible. Runs are immutable; this rebuilds the affected
    # ones (explicitly colored runs keep their color). No-op for
    # non-monospace runs.
    def self.fade_code_runs(runs : Array(TextRun),
                            visuals : Visuals) : Array(TextRun)
      runs.map do |r|
        if r.family == "monospace" &&
           (r.color.nil? || r.color == visuals.text_color)
          TextRun.new(r.text, r.size,
            visuals.fade_color(visuals.text_color, 0.72), r.underline?,
            r.family, r.bold?, r.italic?, r.strikethrough?, r.background)
        else
          r
        end
      end
    end

    # byte classes for the scanner
    private BACKSLASH = 0x5C_u8
    private BACKTICK  = 0x60_u8
    private STAR      = 0x2A_u8
    private TILDE     = 0x7E_u8
    private LBRACKET  = 0x5B_u8
    private RBRACKET  = 0x5D_u8
    private LPAREN    = 0x28_u8
    private RPAREN    = 0x29_u8
    private BANG      = 0x21_u8

    private def parse_inline(src : String, runs : Array(TextRun),
                             links : Array(LinkSpan), size : Float64,
                             color : Color32, bold : Bool, italic : Bool,
                             family : String?, link_color : Color32,
                             strike : Bool = false) : Nil
      plain = String::Builder.new

      flush = ->{
        s = plain.to_s
        plain = String::Builder.new
        runs << TextRun.new(s, size, color, false, family, bold,
          italic, strike) unless s.empty?
      }

      bytes = src.to_unsafe
      total = src.bytesize
      i = 0
      while i < total
        case bytes[i]
        when BACKSLASH
          nxt_i = i + 1 < total ? bytes[i + 1] : nil
          if nxt_i && nxt_i.in?(STAR, BACKTICK, TILDE, BACKSLASH, LBRACKET,
                               RBRACKET)
            plain << nxt_i.unsafe_chr
            i += 2
          else
            plain << "\\"
            i += 1
          end
        when BACKTICK
          close = src.byte_index('`', i + 1)
          if close
            flush.call
            runs << TextRun.new(src.byte_slice(i + 1, close - i - 1),
              size, color, false, "monospace", bold, italic, strike)
            i = close + 1
          else
            plain << "`"
            i += 1
          end
        when TILDE
          # ~~strike~~ — `~` alone is prose (subtitle scores, ranges).
          tildes = 1
          while i + tildes < total && bytes[i + tildes] == TILDE
            tildes += 1
          end
          if tildes >= 2 && (close = find_run_close(src, i + tildes, TILDE, 2))
            flush.call
            inner = src.byte_slice(i + 2, close - i - 2)
            parse_inline(inner, runs, links, size, color, bold, italic,
              family, link_color, true)
            i = close + 2
          else
            tildes.times { plain << "~" }
            i += tildes
          end
        when STAR
          stars = 1
          while i + stars < total && bytes[i + stars] == STAR
            stars += 1
          end
          em_bold = stars >= 2
          em_italic = stars.odd?
          if (close = find_star_close(src, i + stars, stars))
            flush.call
            inner = src.byte_slice(i + stars, close - i - stars)
            parse_inline(inner, runs, links, size, color,
              bold || em_bold, italic || em_italic, family, link_color,
              strike)
            i = close + stars
          else
            stars.times { plain << "*" }
            i += stars
          end
        when BANG
          # Inline image `![alt](url)`: a text galley can't embed
          # pixels, so prose images render as their ALT text (the
          # standalone-image block gets a real Image widget on the
          # markdown side). Not a link — no underline.
          if i + 1 < total && bytes[i + 1] == LBRACKET &&
             (close_br = src.byte_index(']', i + 2)) &&
             close_br + 1 < total && bytes[close_br + 1] == LPAREN &&
             (close_par = src.byte_index(')', close_br + 2))
            flush.call
            runs << TextRun.new(
              src.byte_slice(i + 2, close_br - i - 2), size, color,
              false, family, bold, italic, strike)
            i = close_par + 1
          else
            plain << "!"
            i += 1
          end
        when LBRACKET
          close_br = src.byte_index(']', i + 1)
          if close_br && close_br + 1 < total &&
             bytes[close_br + 1] == LPAREN &&
             (close_par = src.byte_index(')', close_br + 2))
            flush.call
            label = src.byte_slice(i + 1, close_br - i - 1)
            url = src.byte_slice(close_br + 2, close_par - close_br - 2)
            from = runs.sum(&.text.size)
            runs << TextRun.new(label, size, link_color, true, family,
              bold, italic, strike)
            links << LinkSpan.new(from, from + label.size, url)
            i = close_par + 1
          else
            plain << "["
            i += 1
          end
        else
          # Copy the whole run of ordinary bytes in one slice — the
          # common case (plain prose) must not allocate per byte.
          # `!` breaks the run: it may open an inline image.
          j = i + 1
          while j < total
            break if bytes[j].in?(BACKSLASH, BACKTICK, STAR, TILDE,
                                  LBRACKET, BANG)
            j += 1
          end
          plain << src.byte_slice(i, j - i)
          i = j
        end
      end
      flush.call
    end

    # Closing emphasis marker: a run of at least `stars` asterisks,
    # not fully escaped (even number of preceding backslashes).
    # Returns the byte index of the run's first asterisk.
    private def find_star_close(src : String, from : Int32,
                                stars : Int32) : Int32?
      find_run_close(src, from, STAR, stars)
    end

    # Closing marker for any run-delimited emphasis: a run of at
    # least `min` consecutive `byte`s (asterisks, tildes), skipping
    # escaped ones — the byte index of the run's first byte.
    private def find_run_close(src : String, from : Int32, byte : UInt8,
                               min : Int32) : Int32?
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
  end
end
