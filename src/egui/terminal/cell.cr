# Grid cells and character width classification.
#
# A Cell is one terminal column: the grapheme's starting codepoint,
# the SGR colors it was written with, and attribute flags. Wide (CJK)
# characters occupy a WIDE cell plus a following CONTINUATION cell so
# column math stays integral; combining marks are attached by appending
# them to the cell's String when painting (they render on top of the
# base glyph).

module Egui
  module Terminal
    struct Cell
      BOLD      = 1u16
      DIM       = 2u16
      ITALIC    = 4u16
      UNDERLINE = 8u16
      BLINK     = 16u16
      REVERSE   = 32u16
      INVISIBLE = 64u16
      STRIKE    = 128u16
      # Wide char continuation: not drawn, skipped by the cursor.
      CONTINUATION = 256u16

      getter cp : UInt32
      getter fg : TermColor
      getter bg : TermColor
      getter flags : UInt16
      getter comb : Array(UInt32)?

      def self.blank : Cell
        new(0)
      end

      def initialize(@cp : UInt32, @fg : TermColor = TermColor.default_fg,
                     @bg : TermColor = TermColor.default_bg,
                     @flags : UInt16 = 0u16)
        @comb = nil
      end

      def with_combining(mark : UInt32) : Cell
        cell = Cell.new(@cp, @fg, @bg, @flags)
        marks = (@comb || Array(UInt32).new).dup
        marks << mark
        cell.attach(marks)
        cell
      end

      protected def attach(marks : Array(UInt32)) : Nil
        @comb = marks
      end

      def blank? : Bool
        @cp == 0 && @comb.nil?
      end

      def wide? : Bool
        (@flags & CONTINUATION) == 0 && CharWidth.width(@cp) == 2
      end

      def continuation? : Bool
        (@flags & CONTINUATION) != 0
      end

      def attrs?(flag : UInt16) : Bool
        (@flags & flag) != 0
      end

      # The char painted here (' ' for blanks; continuation cells draw
      # nothing but still report a space for text extraction).
      def char : Char
        return ' ' if @cp == 0
        @cp <= 0x10FFFF && !(@cp >= 0xD800 && @cp <= 0xDFFF) ? @cp.chr : '?'
      end
    end

    # Terminal-relevant wcwidth: 0 for combining marks, 2 for East
    # Asian wide/emoji ranges, 1 otherwise. A compact range table —
    # not the full Unicode wcwidth, but it covers what shells, editors
    # and monitors actually emit.
    module CharWidth
      record Range, first : UInt32, last : UInt32, width : Int32

      RANGES = [
        # Combining marks (width 0)
        Range.new(0x0300, 0x036F, 0), Range.new(0x0483, 0x0489, 0),
        Range.new(0x0591, 0x05BD, 0), Range.new(0x05BF, 0x05BF, 0),
        Range.new(0x0610, 0x061A, 0), Range.new(0x064B, 0x065F, 0),
        Range.new(0x0670, 0x0670, 0), Range.new(0x06D6, 0x06DC, 0),
        Range.new(0x0730, 0x074A, 0), Range.new(0x07A6, 0x07B0, 0),
        Range.new(0x0900, 0x0903, 0), Range.new(0x093A, 0x094F, 0),
        Range.new(0x0951, 0x0957, 0), Range.new(0x0E31, 0x0E31, 0),
        Range.new(0x0E34, 0x0E3A, 0), Range.new(0x0E47, 0x0E4E, 0),
        Range.new(0x200B, 0x200F, 0), Range.new(0x202A, 0x202E, 0),
        Range.new(0x2060, 0x2064, 0), Range.new(0x20D0, 0x20F0, 0),
        Range.new(0xFE00, 0xFE0F, 0), Range.new(0xFE20, 0xFE2F, 0),
        # East Asian wide + fullwidth + emoji (width 2)
        Range.new(0x1100, 0x115F, 2), Range.new(0x231A, 0x231B, 2),
        Range.new(0x2329, 0x232A, 2), Range.new(0x23E9, 0x23EC, 2),
        Range.new(0x23F0, 0x23F0, 2), Range.new(0x23F3, 0x23F3, 2),
        Range.new(0x25FD, 0x25FE, 2), Range.new(0x2614, 0x2615, 2),
        Range.new(0x2648, 0x2653, 2), Range.new(0x267F, 0x267F, 2),
        Range.new(0x2693, 0x2693, 2), Range.new(0x26A1, 0x26A1, 2),
        Range.new(0x26AA, 0x26AB, 2), Range.new(0x26BD, 0x26BE, 2),
        Range.new(0x26C4, 0x26C5, 2), Range.new(0x26CE, 0x26CE, 2),
        Range.new(0x26D4, 0x26D4, 2), Range.new(0x26EA, 0x26EA, 2),
        Range.new(0x26F2, 0x26F3, 2), Range.new(0x26F5, 0x26F5, 2),
        Range.new(0x26FA, 0x26FA, 2), Range.new(0x26FD, 0x26FD, 2),
        Range.new(0x2705, 0x2705, 2), Range.new(0x270A, 0x270B, 2),
        Range.new(0x2728, 0x2728, 2), Range.new(0x274C, 0x274C, 2),
        Range.new(0x274E, 0x274E, 2), Range.new(0x2753, 0x2755, 2),
        Range.new(0x2757, 0x2757, 2), Range.new(0x2795, 0x2797, 2),
        Range.new(0x27B0, 0x27B0, 2), Range.new(0x27BF, 0x27BF, 2),
        Range.new(0x2B1B, 0x2B1C, 2), Range.new(0x2B50, 0x2B50, 2),
        Range.new(0x2B55, 0x2B55, 2),
        Range.new(0x2E80, 0x303E, 2), Range.new(0x3041, 0x33FF, 2),
        Range.new(0x3400, 0x4DBF, 2), Range.new(0x4E00, 0x9FFF, 2),
        Range.new(0xA000, 0xA4CF, 2), Range.new(0xA960, 0xA97F, 2),
        Range.new(0xAC00, 0xD7A3, 2), Range.new(0xF900, 0xFAFF, 2),
        Range.new(0xFE10, 0xFE19, 2), Range.new(0xFE30, 0xFE6F, 2),
        Range.new(0xFF00, 0xFF60, 2), Range.new(0xFFE0, 0xFFE6, 2),
        Range.new(0x16FE0, 0x16FE4, 2), Range.new(0x17000, 0x18AFF, 2),
        Range.new(0x1B000, 0x1B2FF, 2),
        Range.new(0x1F004, 0x1F004, 2), Range.new(0x1F0CF, 0x1F0CF, 2),
        Range.new(0x1F18E, 0x1F18E, 2), Range.new(0x1F191, 0x1F19A, 2),
        Range.new(0x1F200, 0x1F320, 2), Range.new(0x1F32D, 0x1F335, 2),
        Range.new(0x1F337, 0x1F37C, 2), Range.new(0x1F37E, 0x1F393, 2),
        Range.new(0x1F3A0, 0x1F3CA, 2), Range.new(0x1F3CF, 0x1F3D3, 2),
        Range.new(0x1F3E0, 0x1F3F0, 2), Range.new(0x1F3F4, 0x1F3F4, 2),
        Range.new(0x1F3F8, 0x1F43E, 2), Range.new(0x1F440, 0x1F440, 2),
        Range.new(0x1F442, 0x1F4FC, 2), Range.new(0x1F4FF, 0x1F53D, 2),
        Range.new(0x1F54B, 0x1F54E, 2), Range.new(0x1F550, 0x1F567, 2),
        Range.new(0x1F57A, 0x1F57A, 2), Range.new(0x1F595, 0x1F596, 2),
        Range.new(0x1F5A4, 0x1F5A4, 2), Range.new(0x1F5FB, 0x1F64F, 2),
        Range.new(0x1F680, 0x1F6C5, 2), Range.new(0x1F6CC, 0x1F6CC, 2),
        Range.new(0x1F6D0, 0x1F6D2, 2), Range.new(0x1F6EB, 0x1F6EC, 2),
        Range.new(0x1F6F4, 0x1F6FC, 2), Range.new(0x1F7E0, 0x1F7EB, 2),
        Range.new(0x1F90C, 0x1F9FF, 2), Range.new(0x1FA70, 0x1FAFF, 2),
        Range.new(0x20000, 0x2FFFD, 2), Range.new(0x30000, 0x3FFFD, 2),
      ]

      # `RANGES` is sorted; binary-search the width.
      def self.width(cp : UInt32) : Int32
        lo = 0
        hi = RANGES.size - 1
        while lo <= hi
          mid = (lo + hi) // 2
          r = RANGES.unsafe_fetch(mid)
          return r.width if cp >= r.first && cp <= r.last
          if cp < r.first
            hi = mid - 1
          else
            lo = mid + 1
          end
        end
        1
      end
    end
  end
end
