# egui's font/text-measurement seam (fonts.rs upstream): the core needs
# `measure` to size widgets; the backend installs a real font
# (fontstash) while specs run headless with the monospace estimate.
#
# `layout` (epaint `Fonts::layout_job` → Galley) is a template method
# on top of `measure`: greedy word-wrap, newlines break rows, over-long
# words hard-break by character.

module Egui
  abstract class Fonts
    # Estimated line height as a font-size factor (matches MonospaceFonts;
    # used by containers that need a row height before measuring).
    LINE_H_FACTOR = 1.3

    # Source font FILE this stack was built from (nil for synthetic
    # stacks) — `Context#primary_family_name` reads the weight axis
    # family through it. Set by the backends' from_system builders.
    property source_path : String? = nil

    abstract def measure(text : String, size : Float64) : Vec2

    # {ascender, descender} in px at a size (descender negative) — the
    # baseline geometry `#layout` bakes into each row. The estimate here
    # (em = 1.3×size) matches MonospaceFonts#measure's height; real
    # stacks override it with the face's metrics (AtlasFonts).
    def metrics_at(size : Float64) : {Float64, Float64}
      {size, -size * 0.3}
    end

    # Memoized `measure` for STATIC text (label-like widgets — see
    # AtlasFonts#measure_cached for the cache design). The base class
    # and every non-AtlasFonts backend just measure; only the real
    # font stacks gain a cache, so headless specs see identical
    # behavior either way.
    def measure_cached(text : String, size : Float64) : Vec2
      measure(text, size)
    end

    # Truncate `text` with an ellipsis so it measures at most
    # `max_width` (upstream's galley truncation). Returns the text
    # unchanged when it already fits, "…" when only the ellipsis
    # fits, "" when not even that does. Binary-searches the prefix
    # length through `measure_cached`, so a squeezed widget pays
    # O(log n) measures.
    def fit(text : String, size : Float64, max_width : Float64) : String
      return text if measure_cached(text, size).x <= max_width
      ell = "…"
      return "" if measure_cached(ell, size).x > max_width
      chars = text.chars
      lo = 0
      hi = chars.size
      best = ell
      while lo < hi
        mid = (lo + hi) // 2
        candidate = chars[0, mid].join + "…"
        if measure_cached(candidate, size).x <= max_width
          best = candidate
          lo = mid + 1
        else
          hi = mid
        end
      end
      best
    end

    # Memoized layouts (upstream caches galleys in Fonts too): a
    # widget re-layouts its text every frame, which is fine for labels
    # but pins a textarea with a multi-megabyte buffer to a full
    # re-wrap (measure per word) at every frame. Keys compare by
    # String identity first (`==` short-circuits on the same object),
    # so an unchanged buffer hits in O(1). Small MRU ring — enough for
    # the handful of texts on screen at one size and wrap width.
    LAYOUT_CACHE_MAX = 8

    private class LayoutCacheEntry
      getter text : String
      getter size : Float64
      getter max_width : Float64?
      getter color : Color32?
      getter? underline : Bool
      getter family : String?
      getter? bold : Bool
      getter? italic : Bool
      getter line_height : Float64?
      getter galley : Galley

      def initialize(@text, @size, @max_width, @color, @underline,
                     @family, @bold, @italic, @line_height, @galley)
      end
    end

    @layout_cache = [] of LayoutCacheEntry

    # Lay styled runs out into rows. `max_width` nil = never wrap.
    # `resolve` maps a run's `family` + bold/italic flags to its font
    # stack (a `Context#fonts_for` closure) so runs tagged with another
    # family (inline monospace code) or a real variant face MEASURE
    # through that stack; nil measures everything through `self` (the
    # historical behavior — fine when no run carries a family/variant).
    # `line_height` nil = the LINE_H_FACTOR default; a paragraph-style
    # label passes a roomier factor (markdown body: 1.5) so decorated
    # runs (the inline-code chip) fit inside the line box.
    def layout(runs : Array(TextRun),
               max_width : Float64? = nil,
               resolve : ((String?, Bool, Bool) -> Fonts)? = nil,
               line_height : Float64? = nil) : Galley
      if runs.size == 1
        run = runs.first
        # The style rides the key: run color and underline are baked
        # into the galley's rows, so a state-recolor of the same text
        # (a hovered link) must not hit a differently-styled entry.
        @layout_cache.each do |e|
          if e.size == run.size && e.max_width == max_width &&
             e.text == run.text && e.color == run.color &&
             e.underline? == run.underline? && e.family == run.family &&
             e.bold? == run.bold? && e.italic? == run.italic? &&
             e.line_height == line_height
            Egui::Bench.count("fonts.layout.hit")
            hit = e.galley
            @layout_cache.delete(e)
            @layout_cache.push(e) # MRU last
            return hit
          end
        end
        Egui::Bench.count("fonts.layout.miss")
        galley = Egui::Bench.span("Fonts#layout(miss)") { build_galley(runs, max_width, resolve, line_height) }
        {% if env("EGUI_LAYOUT_DEBUG") %}
          STDERR.puts "layout MISS bytes=#{run.text.bytesize} size=#{run.size} mw=#{max_width}"
        {% end %}
        @layout_cache.shift if @layout_cache.size >= LAYOUT_CACHE_MAX
        @layout_cache << LayoutCacheEntry.new(
          run.text, run.size, max_width, run.color, run.underline?,
          run.family, run.bold?, run.italic?, line_height, galley)
        galley
      else
        build_galley(runs, max_width, resolve, line_height)
      end
    end

    private def build_galley(runs : Array(TextRun),
                             max_width : Float64?,
                             resolve : ((String?, Bool, Bool) -> Fonts)?,
                             line_height : Float64?) : Galley
      state = WrapState.new(self, max_width, resolve, line_height)

      # Chip padding boundaries: entering a backgrounded-run streak
      # reserves its left pad (sized by the chip run), leaving reserves
      # the right pad (sized by the LAST chip run — the chip's size,
      # not the following prose's). A streak running to EOF owes its
      # right margin after the loop.
      prev_bg = false
      last_bg_run : TextRun? = nil
      tokenize(runs).each do |text, run, kind|
        bg = !run.background.nil?
        if bg != prev_bg
          margin_run = bg ? run : last_bg_run
          state.add_margin(margin_run.not_nil!) if margin_run
          last_bg_run = bg ? run : nil
          prev_bg = bg
        end
        case kind
        when :break  then state.break_row
        when :space  then state.add_space(text, run)
        when :word   then state.add_word(text, run)
        end
      end
      state.add_margin(last_bg_run.not_nil!) if last_bg_run
      state.flush

      Galley.new(state.rows)
    end

    # Greedy word-wrap accumulator: collects (text, style, width)
    # tokens into rows, merging same-style neighbours. Each token
    # carries the width it was measured at — build_row just sums them
    # instead of re-measuring every token (measure is the expensive
    # call; wrap already paid for it once). Tokens keep the whole
    # source TextRun for style: measuring goes through the run's
    # family stack (see #stack_for), and build_row copies its
    # size/color/underline/family/bold/italic into the RowRun.
    private class WrapState
      alias Token = Tuple(String, TextRun, Float64)

      getter rows = [] of Galley::Row
      property tokens = [] of Token
      property width = 0.0
      property height = 0.0
      property y = 0.0
      # Union em-box of the tokens buffered for the row to be emitted:
      # max ascent / deepest descent across their stacks. Empty row →
      # {0, 0} → ascent = height/2 (the old row-center anchor).
      property asc = 0.0
      property desc = 0.0
      # Whether the row to be emitted sits right after a '\n' break
      # (blank lines emit empty rows so byte offsets stay mappable).
      property newline_before = false

      def initialize(@fonts : Fonts, @max_width : Float64?,
                     @resolve : ((String?, Bool, Bool) -> Fonts)?,
                     @line_height : Float64?)
      end

      # The stack a token measures through: the run's family + variant
      # flags resolved through the caller's resolver (Context#fonts_for),
      # `self` for family-less runs or when nobody resolved (headless
      # callers).
      private def stack_for(family : String?, bold : Bool,
                            italic : Bool) : Fonts
        if family.nil? && !bold && !italic
          @fonts
        elsif (r = @resolve)
          r.call(family, bold, italic)
        else
          @fonts
        end
      end

      def flush : Nil
        # A trailing '\n' still owes an empty final row; a wrap flush
        # with nothing buffered owes nothing.
        return if @tokens.empty? && !@newline_before
        emit_row
      end

      def break_row : Nil
        # A newline always ends the current line — even an empty one.
        emit_row
        @newline_before = true
      end

      private def emit_row : Nil
        height = (@height > 0 ? @height : 16.0) *
                 (@line_height || LINE_H_FACTOR)
        # Shared baseline of the row, from the union em-box (max ascent
        # to deepest descent over the row's runs). Two distributions:
        # an EXPLICIT line_height means paragraph-style layout — the
        # extra leading splits half above / half below the em box
        # (CSS/GitHub half-leading), so text and its decorations (the
        # inline-code chip) sit centered in the roomy line box; the
        # default keeps the legacy geometry (em box centered on the row
        # center, baseline below it) so tight rows everywhere render
        # pixel-identically to before. Either way mixed rows (inline
        # code) align on ONE baseline instead of per-font centers.
        em = @asc - @desc
        ascent = @line_height ? (height - em) / 2.0 + @asc
                              : (height + em) / 2.0
        @rows << build_row(@tokens, @y, height, ascent, @newline_before)
        @y += height
        @tokens = [] of Token
        @width = 0.0
        @height = 0.0
        @asc = 0.0
        @desc = 0.0
        @newline_before = false
      end

      def add_space(text : String, run : TextRun) : Nil
        stack = stack_for(run.family, run.bold?, run.italic?)
        w = stack.measure(text, run.size).x
        @tokens << {text, run, w}
        @width += w
        @height = {@height, run.size}.max
        asc, desc = stack.metrics_at(run.size)
        @asc = {@asc, asc}.max
        @desc = {@desc, desc}.min
      end

      # Reserve horizontal room for a chip's padding (a backgrounded
      # run): an EMPTY token of pad width, so the chip — which extends
      # run.size*0.4 beyond its glyphs on each side — never overlaps
      # the neighbouring text's advances (CSS inline padding takes
      # horizontal space; the empty token keeps the row text, and with
      # it caret/selection indexes, unchanged).
      def add_margin(run : TextRun) : Nil
        w = run.size * 0.4
        @tokens << {"", run, w}
        @width += w
      end

      def add_word(word : String, run : TextRun) : Nil
        @height = {@height, run.size}.max
        stack = stack_for(run.family, run.bold?, run.italic?)
        asc, desc = stack.metrics_at(run.size)
        @asc = {@asc, asc}.max
        @desc = {@desc, desc}.min
        w = stack.measure(word, run.size).x
        if (mw = @max_width) && !@tokens.empty? && @width + w > mw
          flush
        end
        if (mw = @max_width) && w > mw
          # hard-break a word longer than the whole width
          word.each_char do |ch|
            cw = stack.measure(ch.to_s, run.size).x
            if @width + cw > mw && !@tokens.empty?
              flush
            end
            @tokens << {ch.to_s, run, cw}
            @width += cw
          end
        else
          @tokens << {word, run, w}
          @width += w
        end
      end

      private def build_row(tokens : Array(Token), y : Float64,
                            height : Float64, ascent : Float64,
                            newline : Bool) : Galley::Row
        runs = [] of Galley::RowRun
        x = 0.0
        tokens.each do |text, run, width|
          # An EMPTY token (a chip side margin — see #add_margin) is
          # pure advance width: no run, so a following same-style run
          # starts after the margin instead of merging back over it.
          if text.empty?
            x += width
            next
          end
          last = runs.last?
          if last && last.size == run.size && last.color == run.color &&
             last.underline? == run.underline? &&
             last.strikethrough? == run.strikethrough? &&
             last.background == run.background &&
             last.family == run.family &&
             last.bold? == run.bold? && last.italic? == run.italic?
            runs[-1] = Galley::RowRun.new(last.text + text, last.x,
              run.size, run.color, run.underline?, run.family,
              run.bold?, run.italic?, run.strikethrough?, run.background)
          else
            runs << Galley::RowRun.new(text, x, run.size, run.color,
              run.underline?, run.family, run.bold?, run.italic?,
              run.strikethrough?, run.background)
          end
          x += width
        end
        Galley::Row.new(runs, x, height, y, ascent, newline)
      end
    end

    # Byte-wise tokenizer: word = maximal run of non-space non-newline
    # bytes, spaces = one merged run, '\n' = a break each. Cutting on
    # byte offsets is UTF-8-safe (space/newline are ASCII, multibyte
    # sequences never contain them) and avoids the per-character string
    # building the old loop did — that was quadratic in word length and
    # re-ran over the whole buffer on every layout.
    private def tokenize(runs : Array(TextRun)) : Array(Tuple(String, TextRun, Symbol))
      tokens = [] of Tuple(String, TextRun, Symbol)
      runs.each do |run|
        text = run.text
        bytes = text.to_unsafe
        size = text.bytesize
        i = 0
        while i < size
          case bytes[i]
          when 0x0A # '\n'
            tokens << {"\n", run, :break}
            i += 1
          when 0x20 # ' '
            j = i + 1
            while j < size && bytes[j] == 0x20
              j += 1
            end
            tokens << {text.byte_slice(i, j - i), run, :space}
            i = j
          else
            j = i + 1
            while j < size && bytes[j] != 0x20 && bytes[j] != 0x0A
              j += 1
            end
            tokens << {text.byte_slice(i, j - i), run, :word}
            i = j
          end
        end
      end
      tokens
    end
  end

  # Headless fallback: fixed-ratio monospace metrics. Deterministic —
  # specs rely on layout being identical across frames.
  class MonospaceFonts < Fonts
    CHAR_W = 0.6
    LINE_H = LINE_H_FACTOR

    def measure(text : String, size : Float64) : Vec2
      # Allocation-free scan (the old split-per-call added up on big
      # layouts): count lines and the widest line's characters.
      lines = 1
      widest = 0
      current = 0
      text.each_char do |ch|
        if ch == '\n'
          lines += 1
          widest = current if current > widest
          current = 0
        else
          current += 1
        end
      end
      widest = current if current > widest
      Vec2.new(widest * size * CHAR_W, lines * size * LINE_H)
    end
  end
end
