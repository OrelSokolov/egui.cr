# The cell grid: `rows` visible lines plus a bounded scrollback above
# them, all in one deque (the visible area is the LAST `rows` entries).
# The alternate screen is the same class with a zero scrollback.
#
# Line addressing is "screen row" (0 = top visible row); absolute
# addresses (selection, rendering with a display offset) go through
# `line_index`/`absolute_line`.

module Egui
  module Terminal
    class Grid
      getter cols : Int32
      getter rows : Int32
      getter scrollback : Int32
      getter lines : Deque(Array(Cell))

      def initialize(@cols : Int32, @rows : Int32, @scrollback : Int32)
        @lines = Deque.new(rows) { blank_line }
      end

      def blank_line : Array(Cell)
        Array.new(@cols, Cell.blank)
      end

      def blank_line(bg : TermColor) : Array(Cell)
        Array.new(@cols, Cell.new(0, bg: bg))
      end

      # Deque index of screen row `y` (no display offset).
      def line_index(y : Int32) : Int32
        @lines.size - @rows + y
      end

      def line(y : Int32) : Array(Cell)
        @lines[line_index(y)]
      end

      # Deque index of screen row `y` shown `display_offset` lines back.
      def visible_index(display_offset : Int32, y : Int32) : Int32
        line_index(y) - display_offset.clamp(0, scrollback_used)
      end

      def scrollback_used : Int32
        @lines.size - @rows
      end

      # Scroll the region [top, bottom] up by `n`. When `history` is
      # set and the region is the full screen, lines leaving the top
      # land in the scrollback (they simply stay in the deque while new
      # lines are appended at the bottom); otherwise they are lost.
      def scroll_up(n : Int32, top = 0, bottom = -1, history = false) : Nil
        bottom = @rows - 1 if bottom < 0
        return if top < 0 || bottom >= @rows || top >= bottom
        n = {n, bottom - top + 1}.min
        return if n <= 0
        if history && top == 0 && bottom == @rows - 1
          n.times do
            @lines.push(blank_line)
            while @lines.size > @rows + @scrollback
              @lines.shift
            end
          end
        else
          base = line_index(0)
          n.times do
            @lines.delete_at(base + top)
            @lines.insert(base + bottom, blank_line)
          end
        end
      end

      # Scroll the region [top, bottom] down by `n` (blank lines enter
      # at the top of the region; the region's bottom lines are lost,
      # rows outside stay — delete before insert, like insert_lines).
      def scroll_down(n : Int32, top = 0, bottom = -1) : Nil
        bottom = @rows - 1 if bottom < 0
        return if top < 0 || bottom >= @rows || top >= bottom
        n = {n, bottom - top + 1}.min
        return if n <= 0
        n.times do
          top_idx = line_index(top)
          bot_idx = line_index(bottom)
          @lines.delete_at(bot_idx)
          @lines.insert(top_idx, blank_line)
        end
      end

      # Insert/delete `n` blank lines at row `y` (scroll region work —
      # rows below `y` inside the region shift down/up). Lines pushed
      # past the region bottom are lost; rows OUTSIDE the region stay.
      # Delete before insert: an insert-first shuffle would drift the
      # deque's tail (the visible window is its last `rows` lines).
      def insert_lines(y : Int32, n : Int32, bottom : Int32) : Nil
        return if y > bottom
        n = {n, bottom - y + 1}.min
        n.times do
          top_idx = line_index(y)
          bot_idx = line_index(bottom)
          @lines.delete_at(bot_idx)
          @lines.insert(top_idx, blank_line)
        end
      end

      def delete_lines(y : Int32, n : Int32, bottom : Int32) : Nil
        return if y > bottom
        n = {n, bottom - y + 1}.min
        n.times do
          y_idx = line_index(y)
          bot_idx = line_index(bottom)
          @lines.delete_at(y_idx)
          @lines.insert(bot_idx, blank_line)
        end
      end

      def clear_scrollback : Nil
        (@lines.size - @rows).times { @lines.shift }
      end

      # Resize, xterm-style without reflow: long lines truncate to the
      # new width. Growing reveals scrollback lines above the content
      # and pads BLANK ROWS AT THE BOTTOM (content stays top-anchored —
      # a fresh 24-row screen resized to 34 keeps its prompt on row 0);
      # shrinking pushes the surplus top rows into the scrollback, so
      # the bottom stays visible.
      def resize(new_cols : Int32, new_rows : Int32) : Nil
        return if new_cols == @cols && new_rows == @rows
        return if new_cols <= 0 || new_rows <= 0
        if new_cols != @cols
          delta = new_cols - @cols
          @lines.each do |l|
            if delta < 0
              l.truncate(0, new_cols)
            else
              l.concat(Array.new(delta, Cell.blank))
            end
          end
          @cols = new_cols
        end
        if new_rows != @rows
          if new_rows < @rows
            # Visible rows shrink; the surplus top rows stay in the
            # deque as scrollback (subject to its cap).
            while @lines.size > @rows + @scrollback
              @lines.shift
            end
          else
            while @lines.size < new_rows
              @lines.push(blank_line)
            end
          end
          @rows = new_rows
        end
      end

      # Plain text of one line, trailing blanks trimmed.
      def line_text(y : Int32) : String
        String.build do |io|
          line(y).each do |cell|
            next if cell.continuation? # wide-char tail: covered by the head
            break if cell.blank?
            io << cell.char
          end
        end
      end
    end
  end
end
