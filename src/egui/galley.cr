# Simplified port of epaint's `Galley`/`LayoutJob` — laid-out text as
# rows of positioned run slices. Built by `Fonts#layout`; consumed by
# `Painter#paint_galley` (and later by TextEdit for caret geometry).

module Egui
  # One styled chunk of text (upstream `LayoutJob` section + format).
  # `family` routes the chunk through another font stack (`nil` = the
  # stack the galley is laid out with); `bold`/`italic` are synthetic
  # (no separate faces — see backend `paint_text`); `strikethrough`
  # paints a line through the row (like `underline`); `background`
  # paints a rounded chip BEHIND the run (inline code).
  class TextRun
    getter text : String
    getter size : Float64
    getter color : Color32?
    getter? underline : Bool
    getter? strikethrough : Bool
    getter family : String?
    getter? bold : Bool
    getter? italic : Bool
    getter background : Color32?

    def initialize(@text : String, @size : Float64,
                   @color : Color32? = nil, @underline : Bool = false,
                   @family : String? = nil, @bold : Bool = false,
                   @italic : Bool = false, @strikethrough : Bool = false,
                   @background : Color32? = nil)
    end
  end

  class Galley
    # A run sliced into a row: same style, positioned by x offset.
    class RowRun
      getter text : String
      getter x : Float64
      getter size : Float64
      getter color : Color32?
      getter? underline : Bool
      getter? strikethrough : Bool
      getter family : String?
      getter? bold : Bool
      getter? italic : Bool
      getter background : Color32?

      def initialize(@text : String, @x : Float64, @size : Float64,
                     @color : Color32?, @underline : Bool,
                     @family : String? = nil, @bold : Bool = false,
                     @italic : Bool = false,
                     @strikethrough : Bool = false,
                     @background : Color32? = nil)
      end
    end

    class Row
      getter runs : Array(RowRun)
      getter width : Float64
      getter height : Float64
      getter y : Float64
      # True when a '\n' in the source text immediately precedes this
      # row (blank-line preservation and byte-offset mapping in
      # TextArea — wrap-broken rows are not preceded by a newline).
      getter? newline_before : Bool

      def initialize(@runs : Array(RowRun), @width : Float64,
                     @height : Float64, @y : Float64,
                     @newline_before : Bool = false)
      end

      # Joined row text, computed once — callers ask for it several
      # times a frame (row starts, caret geometry), and re-joining per
      # call allocates the whole buffer again on big galleys.
      @text_cache : String?

      def text : String
        @text_cache ||= @runs.map(&.text).join
      end
    end

    getter rows : Array(Row)
    getter size : Vec2
    # Character offset of each row start (see row_char_starts), lazily
    # built — mapping caret indexes is O(rows) and ran every frame
    # before, which pinned big galleys to a per-frame full scan.
    @row_starts : Array(Int32)?

    def initialize(@rows : Array(Row))
      width = @rows.map(&.width).max? || 0.0
      height = @rows.empty? ? 0.0 : @rows.last.y + @rows.last.height
      @size = Vec2.new(width, height)
    end

    # Character offset of each row start (size rows+1: the extra entry
    # is the phantom row after a trailing newline). A wrap break
    # consumes no character, a newline break consumes one.
    def row_char_starts : Array(Int32)
      @row_starts ||= begin
        starts = [0]
        @rows.each_with_index do |row, i|
          consumed = row.text.size
          consumed += 1 if @rows[i + 1]?.try(&.newline_before?) || false
          starts << starts[i] + consumed
        end
        starts
      end
    end

    # Character x-offset inside a row (caret geometry for TextEdit):
    # measured on the row's text prefix with the row's dominant size.
    # An empty galley has no rows — the caret just sits at x=0.
    def x_at(row_index : Int32, char_index : Int32,
             fonts : Fonts) : Float64
      row = @rows[row_index]?
      return 0.0 unless row
      size = row.runs.map(&.size).max? || fonts_default
      prefix = row.text[0, {char_index, row.text.size}.min]
      fonts.measure(prefix, size).x
    end

    private def fonts_default : Float64
      16.0
    end
  end
end
