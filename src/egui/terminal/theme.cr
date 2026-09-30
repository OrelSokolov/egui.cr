# Terminal theme: the SGR color space (default / 16-color palette /
# 256-color cube / 24-bit RGB) resolved to `Color32` for painting.
#
# The palette is the classic xterm one by default; a Theme is plain
# data, so apps can swap it for their own scheme.

module Egui
  module Terminal
    # One SGR-resolved color. `Indexed` covers both the 16 ANSI entries
    # (0-15) and the 256-color cube; `DefaultFg`/`DefaultBg` mean "use
    # the theme's foreground/background".
    struct TermColor
      enum Kind
        DefaultFg
        DefaultBg
        Indexed
        Rgb
      end

      getter kind : Kind
      getter index : UInt8   # Indexed only
      getter r : UInt8       # Rgb only
      getter g : UInt8
      getter b : UInt8

      def self.default_fg : TermColor
        new(Kind::DefaultFg)
      end

      def self.default_bg : TermColor
        new(Kind::DefaultBg)
      end

      def self.indexed(index : Int32) : TermColor
        new(Kind::Indexed, index: index.clamp(0, 255).to_u8)
      end

      def self.rgb(r : Int32, g : Int32, b : Int32) : TermColor
        new(Kind::Rgb,
          r: r.clamp(0, 255).to_u8,
          g: g.clamp(0, 255).to_u8,
          b: b.clamp(0, 255).to_u8)
      end

      def initialize(@kind : Kind, index : Int32 = 0,
                     r : Int32 = 0, g : Int32 = 0, b : Int32 = 0)
        @index = index.clamp(0, 255).to_u8
        @r = r.clamp(0, 255).to_u8
        @g = g.clamp(0, 255).to_u8
        @b = b.clamp(0, 255).to_u8
      end

      def ==(other : TermColor) : Bool
        kind == other.kind && index == other.index &&
          r == other.r && g == other.g && b == other.b
      end

      def_hash kind, index, r, g, b

      # Resolve to a paint color through the theme (foreground against
      # `fg: true`, background otherwise — defaults differ).
      def resolve(theme : Theme, fg : Bool) : Color32
        case kind
        in .default_fg? then theme.foreground
        in .default_bg? then theme.background
        in .indexed?    then theme.ansi256(index)
        in .rgb?        then Color32.new(r, g, b, 255)
        end
      end
    end

    # Palette + UI colors for one terminal. Colors are plain data —
    # swap any of them at runtime.
    class Theme
      # The default terminal background as "#rrggbb" — shared with the
      # config Profile defaults so a fresh profile matches the built-in
      # look exactly.
      DEFAULT_BG_HEX = "#16161e"

      # The xterm 16-color palette (dim 0-7, bright 8-15).
      ANSI16 = {
        {0x00, 0x00, 0x00}, {0xcd, 0x3a, 0x3a}, {0x0c, 0xa8, 0x78}, {0xd0, 0xa0, 0x50},
        {0x25, 0x68, 0xd0}, {0xab, 0x5e, 0xab}, {0x2b, 0xaa, 0xaa}, {0xe0, 0xe0, 0xe0},
        {0x7f, 0x7f, 0x7f}, {0xff, 0x77, 0x77}, {0x5d, 0xff, 0xb0}, {0xff, 0xd1, 0x87},
        {0x77, 0x99, 0xff}, {0xe2, 0x82, 0xe2}, {0x66, 0xdd, 0xdd}, {0xff, 0xff, 0xff},
      }

      property background : Color32
      property foreground : Color32
      property cursor : Color32
      property selection_bg : Color32
      # Selection dims the covered text instead of repainting it.
      property selection_overlay : Color32
      property scrollbar : Color32
      # The scrollbar thumb while hovered/dragged (brighter than the
      # resting #scrollbar, the classic grab affordance).
      property scrollbar_active : Color32
      property palette : Array(Color32)

      def initialize
        @background = Color32.new(0x16, 0x16, 0x1e, 255)
        @foreground = Color32.new(0xd4, 0xd4, 0xd4, 255)
        @cursor = Color32.new(0xd4, 0xd4, 0xd4, 120)
        @selection_bg = Color32.new(0x33, 0x55, 0x88, 90)
        @selection_overlay = @selection_bg
        @scrollbar = Color32.new(0x77, 0x77, 0x82, 70)
        @scrollbar_active = Color32.new(0xc0, 0xc0, 0xc8, 120)
        @palette = ANSI16.map { |(r, g, b)| Color32.new(r.to_u8, g.to_u8, b.to_u8, 255) }.to_a
      end

      # Colors 16-255: the 6x6x6 cube and the 24-step grayscale ramp,
      # with xterm's exact component levels.
      def ansi256(index : Int32) : Color32
        idx = index.clamp(0, 255)
        return @palette[idx] if idx < 16
        if idx < 232
          cube = idx - 16
          level = {0, 95, 135, 175, 215, 255}
          r = level[(cube // 36) % 6]
          g = level[(cube // 6) % 6]
          b = level[cube % 6]
          Color32.new(r.to_u8, g.to_u8, b.to_u8, 255)
        else
          gray = 8 + (idx - 232) * 10
          Color32.new(gray.to_u8, gray.to_u8, gray.to_u8, 255)
        end
      end

      # A copy with any of the base colors overridden (nil = keep this
      # theme's value), sharing the ANSI palette array. The terminal
      # widget builds one per frame when `terminal { … }` class rules
      # (or per-element inspector edits) override its colors — the
      # SGR space resolves through it exactly like through the theme.
      def twin(background : Color32? = nil, foreground : Color32? = nil,
               cursor : Color32? = nil,
               selection_overlay : Color32? = nil,
               scrollbar : Color32? = nil,
               scrollbar_active : Color32? = nil) : Theme
        t = Theme.new
        t.background = background || @background
        t.foreground = foreground || @foreground
        t.cursor = cursor || @cursor
        t.selection_bg = @selection_bg
        t.selection_overlay = selection_overlay || @selection_overlay
        t.scrollbar = scrollbar || @scrollbar
        t.scrollbar_active = scrollbar_active || @scrollbar_active
        t.palette = @palette
        t
      end
    end
  end
end
