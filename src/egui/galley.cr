# Simplified port of epaint's `Galley`/`LayoutJob` — laid-out text as
# rows of positioned run slices. Built by `Fonts#layout`; consumed by
# `Painter#paint_galley` (and later by TextEdit for caret geometry).

module Egui
  # One styled chunk of text (upstream `LayoutJob` section + format).
  class TextRun
    getter text : String
    getter size : Float64
    getter color : Color32?
    getter? underline : Bool

    def initialize(@text : String, @size : Float64,
                   @color : Color32? = nil, @underline : Bool = false)
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

      def initialize(@text : String, @x : Float64, @size : Float64,
                     @color : Color32?, @underline : Bool)
      end
    end

    class Row
      getter runs : Array(RowRun)
      getter width : Float64
      getter height : Float64
      getter y : Float64

      def initialize(@runs : Array(RowRun), @width : Float64,
                     @height : Float64, @y : Float64)
      end

      def text : String
        @runs.map(&.text).join
      end
    end

    getter rows : Array(Row)
    getter size : Vec2

    def initialize(@rows : Array(Row))
      width = @rows.map(&.width).max? || 0.0
      height = @rows.empty? ? 0.0 : @rows.last.y + @rows.last.height
      @size = Vec2.new(width, height)
    end

    # Character x-offset inside a row (caret geometry for TextEdit):
    # measured on the row's text prefix with the row's dominant size.
    def x_at(row_index : Int32, char_index : Int32,
             fonts : Fonts) : Float64
      row = @rows[row_index]
      size = row.runs.map(&.size).max? || fonts_default
      prefix = row.text[0, {char_index, row.text.size}.min]
      fonts.measure(prefix, size).x
    end

    private def fonts_default : Float64
      16.0
    end
  end
end
