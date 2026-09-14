# Port of egui_upstream/crates/egui/src/widget_text.rs (subset).
#
# `RichText` is a styled string: chainable size/color/underline
# builders. A widget turns it into `TextRun`s for `Fonts#layout`.

module Egui
  class RichText
    getter text : String
    getter size : Float64?
    getter color : Color32?
    getter? underline : Bool

    def initialize(@text : String, @size : Float64? = nil,
                   @color : Color32? = nil, @underline : Bool = false)
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

    def heading(default_size : Float64) : RichText
      size(default_size * 1.25)
    end

    def small(default_size : Float64) : RichText
      size(default_size * 0.8)
    end

    def weak(default_color : Color32) : RichText
      color(default_color.mul_color(0.6))
    end

    def runs(default_size : Float64, default_color : Color32) : Array(TextRun)
      [TextRun.new(@text, @size || default_size,
        @color || default_color, @underline)]
    end
  end
end
