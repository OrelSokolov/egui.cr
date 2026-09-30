# The terminal emulator state machine output side: cursor, modes,
# scroll regions, SGR pen, charsets, selection and the reply channel
# (DSR/DA answers the child asks for). Pure data + logic — no I/O, no
# widgets; the Parser feeds it, the TermView paints it, the Session
# connects it to a PTY.

module Egui
  module Terminal
    enum MouseMode
      None
      Normal    # 1000: press/release only
      Motion    # 1002: press/release + motion while a button is held
      Any       # 1003: all motion
    end

    enum CursorStyle
      Block
      Bar
      Underline
    end

    class Terminal
      getter grid : Grid            # primary screen (with scrollback)
      getter alt : Grid             # alternate screen (no scrollback)
      getter cursor_x : Int32 = 0
      getter cursor_y : Int32 = 0
      getter theme : Theme
      property cursor_visible : Bool = true
      property cursor_style : CursorStyle = CursorStyle::Block
      property title : String = ""

      # DEC modes apps switch at runtime (the widget reads them to
      # encode keys and route mouse events).
      property? app_cursor_keys : Bool = false
      property? app_keypad : Bool = false
      property? bracketed_paste : Bool = false
      property? origin_mode : Bool = false
      property? insert_mode : Bool = false
      property? wrap_mode : Bool = true
      property mouse_mode : MouseMode = MouseMode::None
      property? sgr_mouse : Bool = false

      # BELs received since `take_bells` — the widget may flash.
      @bells = 0

      # Scroll view: 0 = live (bottom), n = n lines into the history.
      getter display_offset : Int32 = 0
      # Selection endpoints in PRIMARY-grid absolute coordinates
      # (deque index + column); nil when nothing is selected.
      record SelPoint, line : Int32, col : Int32
      property selection : {SelPoint, SelPoint}? = nil

      @alt_active = false
      @pen_fg : TermColor
      @pen_bg : TermColor
      @pen_attrs : UInt16 = 0u16
      @region_top = 0
      @region_bottom : Int32
      @tabstops : Set(Int32)
      @wrap_pending = false
      @last_graphic : UInt32? = nil
      @reply = IO::Memory.new
      @charset_g0 : Symbol = :ascii
      @charset_g1 : Symbol = :ascii
      @charset_active : Int32 = 0 # 0 = G0, 1 = G1 (SO/SI)
      @saved : SavedCursor? = nil
      # NOTE: constructed lazily in `feed` — a Crystal 1.21 bug chokes
      # on mutually-typed constructor recursion (Parser#initialize
      # taking `self`'s type) at two module nesting levels.
      @parser : Parser? = nil

      # DEC Special Graphics (ESC ( 0): the glyph a line-drawing app
      # actually means when it emits these ASCII positions.
      DEC_GRAPHICS = {
        '`' => 0x25C6, 'a' => 0x2592, 'b' => 0x2409, 'c' => 0x240C,
        'd' => 0x240D, 'e' => 0x240A, 'f' => 0x00B0, 'g' => 0x00B1,
        'h' => 0x2424, 'i' => 0x240B, 'j' => 0x2518, 'k' => 0x2510,
        'l' => 0x250C, 'm' => 0x2514, 'n' => 0x253C, 'o' => 0x23BA,
        'p' => 0x23BB, 'q' => 0x2500, 'r' => 0x23BC, 's' => 0x23BD,
        't' => 0x251C, 'u' => 0x2524, 'v' => 0x2534, 'w' => 0x252C,
        'x' => 0x2502, 'y' => 0x2264, 'z' => 0x2265, '{' => 0x03C0,
        '|' => 0x2260, '}' => 0x00A3, '~' => 0x00B7,
      }

      struct SavedCursor
        getter x : Int32
        getter y : Int32
        getter fg : TermColor
        getter bg : TermColor
        getter attrs : UInt16
        getter? origin : Bool

        def initialize(@x, @y, @fg, @bg, @attrs, @origin)
        end
      end

      def initialize(@cols : Int32 = 80, @rows : Int32 = 24,
                     scrollback : Int32 = 10_000,
                     @theme : Theme = Theme.new)
        @grid = Grid.new(@cols, @rows, scrollback)
        @alt = Grid.new(@cols, @rows, 0)
        @region_bottom = @rows - 1
        @pen_fg = TermColor.default_fg
        @pen_bg = TermColor.default_bg
        @tabstops = default_tabstops(@cols)
        # parser is lazy (see feed)
      end

      def cols : Int32
        @grid.cols
      end

      def rows : Int32
        @grid.rows
      end

      def current_grid : Grid
        @alt_active ? @alt : @grid
      end

      def alt_active? : Bool
        @alt_active
      end

      def bells : Int32
        @bells
      end

      def take_bells : Int32
        b = @bells
        @bells = 0
        b
      end

      def feed(bytes : Bytes) : Nil
        parser.feed(bytes)
      end

      def feed(text : String) : Nil
        parser.feed(text)
      end

      private def parser : Parser
        @parser ||= Parser.new(self)
      end

      # Replies (DSR/DA) queued for the child; the Session drains this
      # into the PTY after every feed.
      def drain_output : Bytes?
        return nil if @reply.bytesize == 0
        bytes = @reply.to_slice.dup
        @reply.clear
        bytes
      end

      private def reply(str : String) : Nil
        @reply << str
      end

      # --- printing ----------------------------------------------------

      def print(cp : UInt32) : Nil
        cp = charset_translate(cp)
        width = CharWidth.width(cp)
        if width == 0
          attach_combining(cp)
          return
        end

        grid = current_grid
        cols = grid.cols
        if @wrap_pending
          @wrap_pending = false
          if wrap_mode?
            @cursor_x = 0
            linefeed
            mark_autowrap_row
          end
        end
        if width == 2 && @cursor_x >= cols - 1 && wrap_mode?
          @cursor_x = 0
          linefeed
          mark_autowrap_row
        end

        line = grid.line(@cursor_y)
        if width == 2
          line[@cursor_x] = make_cell(line, @cursor_x, cp, @pen_attrs)
          line[@cursor_x + 1] = Cell.new(0, @pen_fg, @pen_bg, Cell::CONTINUATION) if @cursor_x + 1 < cols
        elsif insert_mode?
          line.insert(@cursor_x, make_cell(line, @cursor_x, cp, @pen_attrs))
          # The WRAPPED marker rides column 0; a cell inserted there
          # takes it over so the line stays a marked continuation.
          if @cursor_x == 0 && line[1]?.try(&.wrapped?)
            line[1] = line[1].not_nil!.without_wrapped
          end
          line.pop
        else
          line[@cursor_x] = make_cell(line, @cursor_x, cp, @pen_attrs)
        end
        @last_graphic = cp

        next_x = @cursor_x + width
        if next_x >= cols
          @cursor_x = cols - 1
          @wrap_pending = true if wrap_mode?
        else
          @cursor_x = next_x
        end
      end

      private def attach_combining(mark : UInt32) : Nil
        return if @cursor_x <= 0
        line = current_grid.line(@cursor_y)
        line[@cursor_x - 1] = line[@cursor_x - 1].with_combining(mark)
      end

      private def charset_translate(cp : UInt32) : UInt32
        set = @charset_active == 0 ? @charset_g0 : @charset_g1
        return cp unless set == :dec_graphics && cp < 0x80
        (DEC_GRAPHICS[cp.chr]? || cp).to_u32
      end

      # The row the autowrap just moved the cursor onto is a wrapped
      # continuation of the previous one — flag it NOW, at print time
      # (alacritty's model), not only in the resize reflow: a line
      # wrapped by the margin while the window was narrow must rejoin
      # when the window widens again. An explicit \r\n never passes
      # through here, so printed newlines stay separate lines.
      private def mark_autowrap_row : Nil
        line = current_grid.line(@cursor_y)
        line[0] = line[0].with_wrapped
      end

      # A printed cell; a write at column 0 KEEPS the line's WRAPPED
      # marker (the flag lives on the first cell, see #mark_autowrap_row
      # — overwriting the cell must not unmark the line).
      private def make_cell(line : Array(Cell), x : Int32, cp : UInt32,
                             attrs : UInt16) : Cell
        cell = Cell.new(cp, @pen_fg, @pen_bg, attrs)
        x == 0 && line[0].wrapped? ? cell.with_wrapped : cell
      end

      # --- C0 controls ---------------------------------------------------

      def execute(b : UInt8) : Nil
        case b
        when 0x07 then @bells += 1
        when 0x08 then @cursor_x -= 1 if @cursor_x > 0; @wrap_pending = false
        when 0x09 then tab_forward
        when 0x0A, 0x0B, 0x0C then linefeed
        when 0x0D then @cursor_x = 0; @wrap_pending = false
        when 0x0E then @charset_active = 1
        when 0x0F then @charset_active = 0
        end
      end

      def linefeed : Nil
        grid = current_grid
        if @cursor_y == @region_bottom
          grid.scroll_up(1, @region_top, @region_bottom, history: !@alt_active)
        elsif @cursor_y < grid.rows - 1
          @cursor_y += 1
        end
      end

      def reverse_index : Nil
        grid = current_grid
        if @cursor_y == @region_top
          grid.scroll_down(1, @region_top, @region_bottom)
        elsif @cursor_y > 0
          @cursor_y -= 1
        end
      end

      def tab_forward : Nil
        x = @tabstops.select { |t| t > @cursor_x }.min?
        @cursor_x = x || current_grid.cols - 1
      end

      def tab_backward : Nil
        x = @tabstops.select { |t| t < @cursor_x }.max?
        @cursor_x = x || 0
      end

      private def default_tabstops(cols : Int32) : Set(Int32)
        stops = Set(Int32).new
        col = 8
        while col < cols
          stops << col
          col += 8
        end
        stops
      end

      # --- ESC dispatch --------------------------------------------------

      def esc_dispatch(inters : String, final : UInt8) : Nil
        case inters
        when ""
          case final
          when '7' then save_cursor
          when '8' then restore_cursor
          when 'D' then linefeed
          when 'E' then @cursor_x = 0; linefeed
          when 'H' then @tabstops << @cursor_x
          when 'M' then reverse_index
          when 'Z' then reply "\e[?6c"
          when 'c' then reset!
          when '=' then @app_keypad = true
          when '>' then @app_keypad = false
          end
        when "#"
          if final == '8'.ord # DECALN: fill the screen with E
            grid = current_grid
            grid.rows.times do |y|
              line = grid.line(y)
              cols.times { |x| line[x] = Cell.new('E'.ord.to_u32) }
            end
            @region_top = 0
            @region_bottom = grid.rows - 1
            move_to(0, 0)
          end
        when "(", ")"
          designate = final == '0'.ord ? :dec_graphics : :ascii
          if inters == "("
            @charset_g0 = designate
          else
            @charset_g1 = designate
          end
        end
      end

      def charset_designate(set : UInt8, final : UInt8) : Nil
        # Only reached via the Parser's ESC ( / ESC ) path (see
        # esc_dispatch); kept for API completeness.
        esc_dispatch(set.chr, final)
      end

      def save_cursor : Nil
        @saved = SavedCursor.new(@cursor_x, @cursor_y, @pen_fg, @pen_bg,
          @pen_attrs, @origin_mode)
      end

      def restore_cursor : Nil
        if (s = @saved)
          @cursor_x = s.x.clamp(0, cols - 1)
          @cursor_y = s.y.clamp(0, rows - 1)
          @pen_fg = s.fg
          @pen_bg = s.bg
          @pen_attrs = s.attrs
          @origin_mode = s.origin?
        else
          move_to(0, 0)
        end
        @wrap_pending = false
      end

      private def move_to(row : Int32, col : Int32) : Nil
        @cursor_y = row.clamp(0, rows - 1)
        @cursor_x = col.clamp(0, cols - 1)
        @wrap_pending = false
      end

      # --- CSI dispatch ----------------------------------------------------

      def csi_dispatch(priv : String, inters : String, params : Array(Int32),
                       final : UInt8) : Nil
        if priv == "?"
          dec_dispatch(params, final)
          return
        end
        p0 = param(params, 0, 1)
        case final
        when '@' then insert_blanks(p0)
        when 'A' then @cursor_y -= limit_up(p0)
        when 'B', 'e' then @cursor_y += limit_down(p0)
        when 'C', 'a' then @cursor_x += p0
        when 'D' then @cursor_x -= p0
        when 'E' then @cursor_y += limit_down(p0); @cursor_x = 0
        when 'F' then @cursor_y -= limit_up(p0); @cursor_x = 0
        when 'G', '`' then @cursor_x = p0 - 1
        when 'H', 'f' then cup(params)
        when 'I' then p0.times { tab_forward }
        when 'J' then erase_display(param(params, 0, 0))
        when 'K' then erase_line(param(params, 0, 0))
        when 'L' then current_grid.insert_lines(@cursor_y, p0, @region_bottom) if in_region?
        when 'M' then current_grid.delete_lines(@cursor_y, p0, @region_bottom) if in_region?
        when 'P' then delete_chars(p0)
        when 'S' then current_grid.scroll_up(p0, @region_top, @region_bottom, history: !@alt_active)
        when 'T' then current_grid.scroll_down(p0, @region_top, @region_bottom)
        when 'X' then erase_chars(p0)
        when 'Z' then p0.times { tab_backward }
        when 'b' then repeat_last(p0)
        when 'd' then @cursor_y = (p0 - 1).clamp(0, rows - 1)
        when 'g' then clear_tabstops(param(params, 0, 0))
        when 'h' then set_modes(params, true)
        when 'l' then set_modes(params, false)
        when 'm' then sgr(params)
        when 'n' then device_status(params)
        when 'c' then reply "\e[?6c" # primary DA: VT102
        when 'r' then set_region(params)
        when 's' then save_cursor
        when 't' then window_op(params)
        when 'u' then restore_cursor
        when 'q'
          if inters == " " # DECSCUSR
            case p0
            when 0, 1, 2 then @cursor_style = CursorStyle::Block
            when 3, 4    then @cursor_style = :bar
            when 5, 6    then @cursor_style = :underline
            end
          end
        end
        clamp_cursor
      end

      private def param(params : Array(Int32), i : Int32, default : Int32) : Int32
        v = params[i]?
        v.nil? || v < 0 ? default : v
      end

      private def limit_up(n : Int32) : Int32
        top = @cursor_y >= @region_top ? @region_top : 0
        {n, @cursor_y - top}.min
      end

      private def limit_down(n : Int32) : Int32
        bottom = @cursor_y <= @region_bottom ? @region_bottom : rows - 1
        {n, bottom - @cursor_y}.min
      end

      private def in_region? : Bool
        @cursor_y >= @region_top && @cursor_y <= @region_bottom
      end

      private def clamp_cursor : Nil
        @cursor_x = @cursor_x.clamp(0, cols - 1)
        @cursor_y = @cursor_y.clamp(0, rows - 1)
      end

      private def cup(params : Array(Int32)) : Nil
        row = param(params, 0, 1) - 1
        col = param(params, 1, 1) - 1
        if origin_mode?
          @cursor_y = (@region_top + row).clamp(@region_top, @region_bottom)
          @cursor_x = col.clamp(0, cols - 1)
        else
          move_to(row, col)
        end
        @wrap_pending = false
      end

      private def insert_blanks(n : Int32) : Nil
        line = current_grid.line(@cursor_y)
        n.times { line.insert(@cursor_x, Cell.blank) }
        n.times { line.pop }
      end

      private def delete_chars(n : Int32) : Nil
        line = current_grid.line(@cursor_y)
        n.times { line.delete_at(@cursor_x) if line.size > @cursor_x }
        n.times { line << blank_cell }
      end

      private def erase_chars(n : Int32) : Nil
        line = current_grid.line(@cursor_y)
        n.times do |i|
          break if @cursor_x + i >= line.size
          line[@cursor_x + i] = blank_cell
        end
      end

      private def repeat_last(n : Int32) : Nil
        cp = @last_graphic
        return if cp.nil?
        n.clamp(1, cols * 2).times { print(cp) }
      end

      private def blank_cell : Cell
        Cell.new(0, bg: @pen_bg)
      end

      private def erase_display(mode : Int32) : Nil
        grid = current_grid
        case mode
        when 0
          erase_in_line(0)
          (@cursor_y + 1...grid.rows).each { |y| replace_line(y, blank_line) }
        when 1
          erase_in_line(1)
          (0...@cursor_y).each { |y| replace_line(y, blank_line) }
        when 2
          grid.rows.times { |y| replace_line(y, blank_line) }
        when 3
          erase_display(2)
          grid.clear_scrollback if grid.same?(@grid)
        end
        @display_offset = 0 if mode == 3
      end

      private def blank_line : Array(Cell)
        Array.new(cols, blank_cell)
      end

      private def replace_line(y : Int32, cells : Array(Cell)) : Nil
        current_grid.lines[current_grid.line_index(y)] = cells
      end

      private def erase_line(mode : Int32) : Nil
        case mode
        when 0 then erase_in_line(0)
        when 1 then erase_in_line(1)
        when 2 then replace_line(@cursor_y, blank_line)
        end
      end

      private def erase_in_line(half : Int32) : Nil
        line = current_grid.line(@cursor_y)
        from = half == 0 ? @cursor_x : 0
        to = half == 0 ? cols - 1 : @cursor_x
        (from..to).each { |x| line[x] = blank_cell if x < line.size }
      end

      private def clear_tabstops(mode : Int32) : Nil
        case mode
        when 0 then @tabstops.delete(@cursor_x)
        when 3 then @tabstops.clear
        end
      end

      private def set_modes(params : Array(Int32), on : Bool) : Nil
        params.each do |p|
          case p
          when 4 then @insert_mode = on
          end
        end
      end

      private def device_status(params : Array(Int32)) : Nil
        case param(params, 0, 0)
        when 5 then reply "\e[0n"
        when 6 then reply "\e[#{@cursor_y + 1};#{@cursor_x + 1}R"
        end
      end

      private def set_region(params : Array(Int32)) : Nil
        top = param(params, 0, 1) - 1
        bottom = param(params, 1, rows) - 1
        return unless top >= 0 && bottom < rows && top < bottom
        @region_top = top
        @region_bottom = bottom
        move_to(origin_mode? ? top : 0, 0)
      end

      private def window_op(params : Array(Int32)) : Nil
        case param(params, 0, 0)
        when 18 then reply "\e[8;#{rows};#{cols}t"
        end
      end

      private def dec_dispatch(params : Array(Int32), final : UInt8) : Nil
        case final
        when 'h', 'l'
          on = final == 'h'.ord
          params.each do |p|
            case p
            when 1    then @app_cursor_keys = on
            when 6    then @origin_mode = on; move_to(on ? @region_top : 0, 0)
            when 7    then @wrap_mode = on; @wrap_pending = false unless on
            when 25   then @cursor_visible = on
            when 47   then self.alt_active = on
            when 1000 then @mouse_mode = on ? MouseMode::Normal : MouseMode::None
            when 1002 then @mouse_mode = on ? MouseMode::Motion : MouseMode::None
            when 1003 then @mouse_mode = on ? MouseMode::Any : MouseMode::None
            when 1006 then @sgr_mouse = on
            when 1047
              self.alt_active = on
              @alt.lines.each_with_index { |_, i| @alt.lines[i] = Array.new(@alt.cols, Cell.blank) } if on
            when 1048 then on ? save_cursor : restore_cursor
            when 1049
              if on
                save_cursor
                self.alt_active = true
                @alt.lines.each_with_index { |_, i| @alt.lines[i] = Array.new(@alt.cols, Cell.blank) }
              else
                self.alt_active = false
                restore_cursor
              end
            when 2004 then @bracketed_paste = on
            end
          end
        end
      end

      def alt_active=(on : Bool) : Nil
        return if @alt_active == on
        @alt_active = on
        @selection = nil # selection lives on the primary grid
        @wrap_pending = false
      end

      # --- SGR -------------------------------------------------------------

      private def sgr(params : Array(Int32)) : Nil
        i = 0
        params = [0] of Int32 if params.empty?
        while i < params.size
          p = params[i]
          case p
          when 0 then reset_pen
          when 1 then @pen_attrs |= Cell::BOLD
          when 2 then @pen_attrs |= Cell::DIM
          when 3 then @pen_attrs |= Cell::ITALIC
          when 4 then @pen_attrs |= Cell::UNDERLINE
          when 5, 6 then @pen_attrs |= Cell::BLINK
          when 7 then @pen_attrs |= Cell::REVERSE
          when 8 then @pen_attrs |= Cell::INVISIBLE
          when 9 then @pen_attrs |= Cell::STRIKE
          when 21 then @pen_attrs |= Cell::UNDERLINE
          when 22 then @pen_attrs &= ~(Cell::BOLD | Cell::DIM)
          when 23 then @pen_attrs &= ~Cell::ITALIC
          when 24 then @pen_attrs &= ~Cell::UNDERLINE
          when 25 then @pen_attrs &= ~Cell::BLINK
          when 27 then @pen_attrs &= ~Cell::REVERSE
          when 28 then @pen_attrs &= ~Cell::INVISIBLE
          when 29 then @pen_attrs &= ~Cell::STRIKE
          when 30..37 then @pen_fg = TermColor.indexed(p - 30)
          when 38
            @pen_fg, i = extended_color(params, i, @pen_fg)
          when 39 then @pen_fg = TermColor.default_fg
          when 40..47 then @pen_bg = TermColor.indexed(p - 40)
          when 48
            @pen_bg, i = extended_color(params, i, @pen_bg)
          when 49 then @pen_bg = TermColor.default_bg
          when 90..97 then @pen_fg = TermColor.indexed(p - 90 + 8)
          when 100..107 then @pen_bg = TermColor.indexed(p - 100 + 8)
          end
          i += 1
        end
      end

      private def extended_color(params : Array(Int32), i : Int32, fallback : TermColor)
        mode = params[i + 1]?
        case mode
        when 2
          r, g, b = params[i + 2]?, params[i + 3]?, params[i + 4]?
          if r && g && b
            return {TermColor.rgb(r, g, b), i + 4}
          end
        when 5
          idx = params[i + 2]?
          return {TermColor.indexed(idx || 0), i + 2} if idx
        end
        {fallback, i}
      end

      private def reset_pen : Nil
        @pen_fg = TermColor.default_fg
        @pen_bg = TermColor.default_bg
        @pen_attrs = 0u16
      end

      # --- OSC ----------------------------------------------------------------

      def osc_dispatch(payload : String) : Nil
        code, _, rest = payload.partition(';')
        case code.to_i?
        when 0, 1, 2 then @title = rest.gsub(/[\e\x00-\x1f]/, "")
        end
      end

      # --- view state -----------------------------------------------------------

      def scroll_display(lines : Int32) : Nil
        @display_offset = (@display_offset + lines).clamp(0, @grid.scrollback_used)
      end

      def reset_scroll : Nil
        @display_offset = 0
      end

      def resize(cols : Int32, rows : Int32) : Nil
        return if cols <= 0 || rows <= 0 || (cols == self.cols && rows == self.rows)
        active = current_grid
        old_rows = active.rows
        old_size = active.lines.size
        # The cursor's absolute line index, tracked through the reflow
        # (wrapped lines split and rejoin under it) and the window
        # shift (the last `rows` lines stay visible); a line trimmed
        # off the top by the scrollback cap drops it to the top row.
        abs = old_size - old_rows + @cursor_y
        line = if @alt_active
                 @grid.resize(cols, rows, reflow: false)
                 @alt.resize(cols, rows, reflow: false, track: abs) || abs
               else
                 tracked = @grid.resize(cols, rows, reflow: true, track: abs) || abs
                 @alt.resize(cols, rows, reflow: false)
                 tracked
               end
        @cursor_y = (line - (current_grid.lines.size - rows)).clamp(0, rows - 1)
        @cursor_x = @cursor_x.clamp(0, cols - 1)
        @region_top = 0
        @region_bottom = rows - 1
        @wrap_pending = false
        @display_offset = @display_offset.clamp(0, @grid.scrollback_used)
        @selection = nil
        @tabstops = default_tabstops(cols)
        @cols = cols
        @rows = rows
      end

      def reset! : Nil
        # Full RIS: fresh grids, pen, modes — but keep geometry so the
        # widget's resize logic stays consistent.
        scrollback = @grid.scrollback
        @grid = Grid.new(cols, rows, scrollback)
        @alt = Grid.new(cols, rows, 0)
        @region_top = 0
        @region_bottom = rows - 1
        @cursor_x = 0
        @cursor_y = 0
        reset_pen
        @pen_fg = TermColor.default_fg
        @pen_bg = TermColor.default_bg
        @tabstops = default_tabstops(cols)
        @wrap_pending = false
        @display_offset = 0
        @selection = nil
        @saved = nil
        @alt_active = false
        @app_cursor_keys = false
        @app_keypad = false
        @bracketed_paste = false
        @origin_mode = false
        @insert_mode = false
        @wrap_mode = true
        @mouse_mode = MouseMode::None
        @sgr_mouse = false
        @cursor_visible = true
        @cursor_style = CursorStyle::Block
        @charset_g0 = :ascii
        @charset_g1 = :ascii
        @charset_active = 0
        @reply.clear
        @parser = nil # mid-sequence parser state resets with RIS
      end

      # --- selection ---------------------------------------------------------------

      def selection_text : String?
        sel = @selection
        return nil if sel.nil? || @alt_active
        a, b = normalize(sel[0], sel[1])
        return nil if a.line == b.line && a.col == b.col
        String.build do |io|
          (a.line..b.line).each do |l|
            line = @grid.lines[l]?
            next unless line
            from = l == a.line ? a.col : 0
            to = l == b.line ? b.col : line.size
            piece = (line[from...to]? || [] of Cell)
            io << piece.reject(&.continuation?).map(&.char).join.rstrip
            io << '\n' unless l == b.line
          end
        end
      end

      def selected?(abs_line : Int32, col : Int32) : Bool
        sel = @selection
        return false if sel.nil? || @alt_active
        a, b = normalize(sel[0], sel[1])
        abs_line >= a.line && abs_line <= b.line &&
          (abs_line != a.line || col >= a.col) &&
          (abs_line != b.line || col < b.col)
      end

      # Double-click selection (SelectionType::Semantic in egui_term /
      # alacritty): the run of non-space cells around (line, col).
      def select_word(line : Int32, col : Int32) : Nil
        return if @alt_active
        cells = @grid.lines[line]? || return
        return if cells.empty?
        col = col.clamp(0, cells.size - 1)
        word_cell = ->(c : Cell) { !c.blank? && !c.char.whitespace? }
        return unless word_cell.call(cells[col])
        from = col
        while from > 0 && word_cell.call(cells[from - 1])
          from -= 1
        end
        to = col + 1
        while to < cells.size && word_cell.call(cells[to])
          to += 1
        end
        @selection = {SelPoint.new(line, from), SelPoint.new(line, to)}
      end

      # Triple-click selection (SelectionType::Lines): the whole line,
      # trailing blanks trimmed by selection_text.
      def select_line(line : Int32) : Nil
        return if @alt_active
        cells = @grid.lines[line]? || return
        @selection = {SelPoint.new(line, 0), SelPoint.new(line, cells.size)}
      end

      private def normalize(p0 : SelPoint, p1 : SelPoint) : {SelPoint, SelPoint}
        if p0.line < p1.line || (p0.line == p1.line && p0.col <= p1.col)
          {p0, p1}
        else
          {p1, p0}
        end
      end

      # --- input helpers (used by the widget through the Session) ---------------

      # Bytes to write for a paste event (bracketed when the child asked).
      def paste_bytes(text : String) : Bytes
        clean = text.gsub(/\r\n|\r|\n/, "\r").gsub('\e', "")
        if bracketed_paste?
          "\e[200~#{clean}\e[201~".to_slice
        else
          clean.to_slice
        end
      end

      # SGR/legacy X10 mouse report bytes, or nil when the child is not
      # listening. `button_code` follows the xterm scheme (0-2 buttons,
      # +32 motion, 64/65 wheel).
      def mouse_bytes(button_code : Int32, pressed : Bool,
                      col : Int32, row : Int32) : Bytes?
        return nil if mouse_mode.none?
        if sgr_mouse?
          "\e[<#{button_code};#{col + 1};#{row + 1}#{pressed ? 'M' : 'm'}".to_slice
        else
          return nil if !pressed
          b = button_code + 32
          return nil if b > 255
          Slice[0x1b_u8, '['.ord.to_u8!, 'M'.ord.to_u8!,
            b.to_u8!, (col + 33).clamp(0, 255).to_u8!,
            (row + 33).clamp(0, 255).to_u8!]
        end
      end
    end
  end
end
