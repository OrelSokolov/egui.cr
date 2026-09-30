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

      # Resize with canonical reflow (the gnome-terminal/alacritty
      # model): the buffer regroups into LOGICAL lines — a row whose
      # first cell carries the WRAPPED flag continues the one above —
      # and re-wraps each at the new width, exactly as if its text had
      # been PRINTED there. Idempotent from any prior fragmentation: a
      # shrink by one column yields full rows plus one short tail, not
      # 1-char remainder fragments. `reflow: false` (the alternate
      # screen) keeps the plain xterm truncate/pad behavior —
      # full-screen apps redraw themselves on SIGWINCH. `track` is a
      # line index carried through the reflow and the scrollback-cap
      # trims — the caller uses it to keep the cursor on its line;
      # returns the updated index (or nil).
      #
      # Row changes are xterm-style without reflow: growing reveals
      # scrollback lines above the content and pads BLANK ROWS AT THE
      # BOTTOM (content stays top-anchored — a fresh 24-row screen
      # resized to 34 keeps its prompt on row 0); shrinking pushes the
      # surplus top rows into the scrollback, so the bottom stays
      # visible.
      def resize(new_cols : Int32, new_rows : Int32, reflow : Bool = true,
                 track : Int32? = nil) : Int32?
        return track if new_cols == @cols && new_rows == @rows
        return track if new_cols <= 0 || new_rows <= 0
        tracked = track
        if new_cols != @cols
          if reflow
            tracked = reflow_lines(new_cols, tracked)
          else
            delta = new_cols - @cols
            @lines.each do |l|
              if delta < 0
                l.truncate(0, new_cols)
              else
                l.concat(Array.new(delta, Cell.blank))
              end
            end
          end
          @cols = new_cols
          # wrapping may have grown the deque — keep the buffer capped
          tracked = trim_to_cap(tracked)
        end
        if new_rows != @rows
          if new_rows < @rows
            # Visible rows shrink; the surplus top rows stay in the
            # deque as scrollback. The cap is enforced against the NEW
            # row count, so the buffer never exceeds scrollback + rows.
            @rows = new_rows
            tracked = trim_to_cap(tracked)
          else
            while @lines.size < new_rows
              @lines.push(blank_line)
            end
            @rows = new_rows
          end
        end
        # A joining reflow can leave the deque SHORT of the row count
        # (two lines merged into one); `line(y)` indexes from the deque
        # tail, so a short deque shifts every screen row — pad back,
        # blanks at the bottom like the row-grow branch above.
        while @lines.size < @rows
          @lines.push(blank_line)
        end
        tracked
      end

      # Cells of actual content: trailing blanks trimmed; a wide
      # char's continuation tail counts (it renders with its head).
      private def content_width(line : Array(Cell)) : Int32
        i = line.size - 1
        while i >= 0 && line[i].blank? && !line[i].continuation?
          i -= 1
        end
        i + 1
      end

      # Canonical reflow: regroup the physical rows into LOGICAL lines
      # — a row whose first cell carries the WRAPPED flag continues the
      # one above — and re-emit every logical line wrapped at
      # `new_cols`, exactly as if its text had been printed at the new
      # width. Handles both directions in one pass and is idempotent:
      # re-running it at the same width changes nothing, and any
      # fragmentation left by earlier resizes converges to the one
      # canonical layout (full rows + one short tail — never 1-char
      # remainder fragments).
      private def reflow_lines(new_cols : Int32, tracked : Int32?) : Int32?
        acc = Deque(Array(Cell)).new(@lines.size)
        emitted = 0
        new_tracked : Int32? = nil

        i = 0
        n = @lines.size
        while i < n
          # One logical line: rows i..j, every row after i flagged as a
          # continuation. Row i's own flag (a dangling continuation at
          # the top of the buffer, past the scrollback cap) rides the
          # group's first chunk so a later widen can still rejoin it.
          cont = @lines[i].first?.try(&.wrapped?) || false
          cells = @lines[i][0, content_width(@lines[i])]
          j = i
          while (j + 1) < n && @lines[j + 1].first?.try(&.wrapped?)
            j += 1
            cells = cells + @lines[j][0, content_width(@lines[j])]
          end
          rows = emit_wrapped(acc, cells, new_cols, cont)
          if tracked && tracked >= i && tracked <= j
            # The tracked row lands on the chunk holding its old
            # position within the logical line.
            offset = 0
            (i...tracked).each { |k| offset += content_width(@lines[k]) }
            new_tracked = emitted + {offset // new_cols, rows - 1}.min
          end
          emitted += rows
          i = j + 1
        end
        @lines = acc
        new_tracked
      end

      # Re-wrap `cells` into rows of `new_cols`, flagging every chunk
      # after the first (and the first too when `cont` — the whole
      # group continues the row above). Returns the rows emitted. A
      # wide char is never split from its continuation tail: when only
      # one column is left and a wide head follows, the chunk ends
      # short and the head starts the next row.
      private def emit_wrapped(acc : Deque(Array(Cell)), cells : Array(Cell),
                               new_cols : Int32, cont : Bool) : Int32
        if cells.empty?
          row = Array.new(new_cols, Cell.blank)
          row[0] = row[0].with_wrapped if cont
          acc << row
          return 1
        end
        rows = 0
        idx = 0
        first = true
        while idx < cells.size
          chunk = Array(Cell).new(new_cols)
          while chunk.size < new_cols && idx < cells.size
            if chunk.size == new_cols - 1 && idx + 1 < cells.size &&
               cells[idx + 1].continuation?
              break
            end
            chunk << cells[idx]
            idx += 1
          end
          while chunk.size < new_cols
            chunk << Cell.blank
          end
          chunk[0] = chunk[0].with_wrapped if !first || cont
          acc << chunk
          rows += 1
          first = false
        end
        rows
      end

      # Drop the oldest lines past the scrollback cap, shifting a
      # tracked index along (it may go negative — the caller clamps).
      private def trim_to_cap(tracked : Int32?) : Int32?
        overflow = @lines.size - @rows - @scrollback
        if overflow > 0
          overflow.times { @lines.shift }
          tracked = tracked - overflow if tracked
        end
        tracked
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
