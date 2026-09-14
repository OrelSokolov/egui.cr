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

    abstract def measure(text : String, size : Float64) : Vec2

    # Lay styled runs out into rows. `max_width` nil = never wrap.
    def layout(runs : Array(TextRun),
               max_width : Float64? = nil) : Galley
      state = WrapState.new(self, max_width)

      tokenize(runs).each do |text, size, color, underline, kind|
        case kind
        when :break  then state.break_row
        when :space  then state.add_space(text, size, color, underline)
        when :word   then state.add_word(text, size, color, underline)
        end
      end
      state.flush

      Galley.new(state.rows)
    end

    # Greedy word-wrap accumulator: collects (text, size, color,
    # underline) tokens into rows, merging same-style neighbours.
    private class WrapState
      alias Token = Tuple(String, Float64, Color32?, Bool)

      getter rows = [] of Galley::Row
      property tokens = [] of Token
      property width = 0.0
      property height = 0.0
      property y = 0.0

      def initialize(@fonts : Fonts, @max_width : Float64?)
      end

      def flush : Nil
        return if @tokens.empty?
        height = (@height > 0 ? @height : 16.0) * LINE_H_FACTOR
        @rows << build_row(@tokens, @y, height)
        @y += height
        @tokens = [] of Token
        @width = 0.0
        @height = 0.0
      end

      def break_row : Nil
        flush
      end

      def add_space(text : String, size : Float64, color : Color32?,
                    underline : Bool) : Nil
        @tokens << {text, size, color, underline}
        @width += @fonts.measure(text, size).x
        @height = {@height, size}.max
      end

      def add_word(word : String, size : Float64, color : Color32?,
                   underline : Bool) : Nil
        @height = {@height, size}.max
        w = @fonts.measure(word, size).x
        if (mw = @max_width) && !@tokens.empty? && @width + w > mw
          flush
        end
        if (mw = @max_width) && w > mw
          # hard-break a word longer than the whole width
          word.each_char do |ch|
            cw = @fonts.measure(ch.to_s, size).x
            if @width + cw > mw && !@tokens.empty?
              flush
            end
            @tokens << {ch.to_s, size, color, underline}
            @width += cw
          end
        else
          @tokens << {word, size, color, underline}
          @width += w
        end
      end

      private def build_row(tokens : Array(Token), y : Float64,
                            height : Float64) : Galley::Row
        runs = [] of Galley::RowRun
        x = 0.0
        tokens.each do |text, size, color, underline|
          last = runs.last?
          if last && last.size == size && last.color == color &&
             last.underline? == underline
            runs[-1] = Galley::RowRun.new(last.text + text, last.x,
              size, color, underline)
          else
            runs << Galley::RowRun.new(text, x, size, color, underline)
          end
          x += @fonts.measure(text, size).x
        end
        Galley::Row.new(runs, x, height, y)
      end
    end

    private def tokenize(runs : Array(TextRun)) : Array(Tuple(String, Float64, Color32?, Bool, Symbol))
      tokens = [] of Tuple(String, Float64, Color32?, Bool, Symbol)
      runs.each do |run|
        buffer = ""
        emit_word = ->(buf : String) do
          tokens << {buf, run.size, run.color, run.underline?, :word}
        end
        run.text.each_char do |ch|
          case ch
          when '\n'
            emit_word.call(buffer) unless buffer.empty?
            buffer = ""
            tokens << {"\n", run.size, run.color, run.underline?, :break}
          when ' '
            emit_word.call(buffer) unless buffer.empty?
            buffer = ""
            tokens << {" ", run.size, run.color, run.underline?, :space}
          else
            buffer += ch
          end
        end
        emit_word.call(buffer) unless buffer.empty?
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
      lines = text.count('\n') + 1
      widest = text.split('\n').map(&.size).max? || 0
      Vec2.new(widest * size * CHAR_W, lines * size * LINE_H)
    end
  end
end
