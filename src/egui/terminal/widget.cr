# TermView — the terminal widget: computes the cell metrics from the
# app font, resizes the session when the rect changes, paints the grid
# (background runs, text runs, selection, cursor) plus a scrollback
# scrollbar (thumb drag, track paging) and translates raw egui input
# into PTY bytes (keys via Terminal::Keymap, mouse reports, wheel
# scrolling, copy/paste).
#
# Usage: `ui.terminal(session)` where session is a Terminal::Backend
# (a Terminal::Session from egui/terminal/pty).

module Egui
  module Terminal
    class TermView
      include Widget

      PAD = 4.0
      # Scrollbar: track strip width and the smallest thumb (draggable)
      # height. The bar lives on the terminal's right edge and shows
      # whenever the primary grid has scrollback.
      BAR_W = 10.0
      THUMB_MIN_H = 18.0

      @cell_w : Float64 = 8.0
      @cell_h : Float64 = 16.0
      @grid_origin : Pos2 = Pos2.zero
      @bar_rect : Rect? = nil
      @bar_grabbed : Bool = false

      def initialize(@backend : Backend,
                     @theme : Theme = Theme.new,
                     @font_size : Float64 = 14.0,
                     @cursor_blinks : Bool = false)
      end

      def ui(ui : Ui) : Response
        fonts = ui.ctx.fonts
        # Exact monospace advance (no rounding): text runs are drawn as
        # whole strings, so a rounded-off cell width makes the cursor
        # drift away from the text as the line grows.
        @cell_w = (fonts.measure("MMMMMMMMMM", @font_size).x / 10)
        @cell_w = {@cell_w, 1.0}.max
        @cell_h = (@font_size * Fonts::LINE_H_FACTOR).round.to_f64

        term = @backend.term
        rect = ui.allocate_at_least(
          Vec2.new(ui.available_width, ui.available_height))

        # The scrollbar strip (right edge). It is carved out of BOTH
        # the cell area and the terminal's own interact rect —
        # overlapping interact rects would make the press hit-test
        # (Memory#topmost_at) ambiguous. Hidden on the alternate
        # screen (no scrollback there) and when history is empty.
        bar_rect = nil
        if !term.alt_active? && term.grid.scrollback_used > 0
          bar_rect = Rect.from_min_size(
            Pos2.new(rect.right - BAR_W, rect.min.y),
            Vec2.new(BAR_W, rect.height))
        end
        @bar_rect = bar_rect
        # Carve the bar strip out of the interact rect: the terminal is
        # clickable up to the bar's LEFT edge (Rect.new takes two
        # CORNERS — using bar_rect.min as the max corner would collapse
        # the height to zero, since the bar starts at rect.min.y).
        interact_rect = bar_rect ?
                          Rect.new(rect.min, Pos2.new(bar_rect.min.x, rect.max.y)) :
                          rect
        response = ui.interact(interact_rect, ui.next_widget_id,
          Sense::Click | Sense::Drag | Sense::Focusable)

        # One evented scheduler pass for the whole frame (Session
        # dedups by frame time — multiple TermViews share it) right
        # before the drain, so data that arrived since the last frame
        # reaches the emulator this same frame.
        @backend.evented_pass(ui.ctx.input.time)
        @backend.pump

        # Grid geometry: fit whole cells, keep the leftover as padding.
        grid_avail_w = rect.width - PAD * 2 - (bar_rect ? BAR_W : 0.0)
        cols = (grid_avail_w / @cell_w).floor.to_i.clamp(2, 500)
        rows = ((rect.height - PAD * 2) / @cell_h).floor.to_i.clamp(2, 250)
        @backend.resize(cols, rows) if cols != term.cols || rows != term.rows

        grid_w = cols * @cell_w
        @grid_origin = Pos2.new(
          rect.min.x + ((grid_avail_w - grid_w) / 2).clamp(PAD, 1e9),
          rect.min.y + PAD)

        handle_scrollbar(ui, bar_rect) if bar_rect
        handle_pointer(ui.ctx, response, rect)
        if response.has_focus?
          # Claim the keyboard while focused: Tab/arrows belong to the
          # child process (shell completion, history), not to focus
          # navigation (upstream EventFilter role).
          ui.ctx.memory.focus.lock_keyboard
          handle_keys(ui.ctx, response)
        end

        paint(ui, rect, cols, rows)

        # Repaint drivers: blinking cursor while focused (only when the
        # blink option is on — a steady cursor needs no repaints of its
        # own); every alive session keeps frames coming (Windows drains
        # the shim's ring buffer per frame; Unix needs the per-frame
        # evented pass that wakes the reader fibers — see
        # Session#evented_pass).
        if response.has_focus? && term.cursor_visible && @cursor_blinks
          ui.ctx.request_repaint
        end
        ui.ctx.request_repaint if @backend.alive?

        response
      end

      # --- painting -----------------------------------------------------

      # Effective SGR colors of a cell: REVERSE (SGR 7) swaps the
      # cell's fg/bg — a default-fg cell then paints its glyphs in the
      # theme background over a foreground-colored background.
      private def effective_bg(cell : Cell) : Color32
        cell.attrs?(Cell::REVERSE) ? cell.fg.resolve(@theme, fg: true)
                                   : cell.bg.resolve(@theme, fg: false)
      end

      private def effective_fg(cell : Cell) : Color32
        cell.attrs?(Cell::REVERSE) ? cell.bg.resolve(@theme, fg: false)
                                   : cell.fg.resolve(@theme, fg: true)
      end

      # The thumb rect for the current scroll position: viewport
      # fraction of the whole content (scrollback + screen). At the
      # bottom (live) the thumb sits at the track's bottom edge.
      private def scrollbar_thumb(track : Rect, term : Terminal) : Rect
        used = term.grid.scrollback_used
        content = used + term.rows
        thumb_h = (track.height * term.rows / content)
                  .clamp(THUMB_MIN_H, track.height)
        top = track.min.y + (track.height - thumb_h) *
              (used - term.display_offset) / {used, 1}.max
        Rect.from_min_size(Pos2.new(track.min.x, top),
          Vec2.new(track.width, thumb_h))
      end

      private def paint_scrollbar(ui : Ui) : Nil
        track = @bar_rect
        return unless track
        p = ui.painter
        # Dark groove, not a white strip: the terminal background is
        # dark, so the track shades DOWN and only the thumb carries
        # light.
        p.rect(track, fill: Color32.new(0, 0, 0, 70))
        color = @bar_grabbed ? @theme.scrollbar_active : @theme.scrollbar
        p.rect(scrollbar_thumb(track, @backend.term), 3.0, fill: color)
      end

      private def handle_scrollbar(ui : Ui, track : Rect) : Nil
        term = @backend.term
        used = term.grid.scrollback_used
        return if used <= 0

        response = ui.interact(track, ui.next_widget_id,
          Sense::Click | Sense::Drag)
        input = ui.ctx.input
        @bar_grabbed = response.hovered? || response.dragged?

        if response.dragged?
          # Absolute positioning: the thumb follows the pointer.
          if (pos = input.pointer_pos) &&
             (room = track.height - scrollbar_thumb(track, term).height) > 0
            frac = ((pos.y - track.min.y -
                     scrollbar_thumb(track, term).height / 2) / room)
                    .clamp(0.0, 1.0)
            target = ((1.0 - frac) * used).round.to_i
            term.scroll_display(target - term.display_offset)
          end
        elsif response.clicked?
          # A plain click on the track pages toward the click: above
          # the thumb = older lines, below = newer.
          if (pos = input.pointer_pos) &&
             pos.y < scrollbar_thumb(track, term).min.y
            term.scroll_display(term.rows)
          else
            term.scroll_display(-term.rows)
          end
        end
      end

      private def paint(ui : Ui, rect : Rect, cols : Int32, rows : Int32) : Nil
        term = @backend.term
        grid = term.current_grid
        p = ui.painter

        # Opaque background — or, when the theme background carries an
        # alpha (the terminal-opacity knob), a REPLACE rect: it
        # overwrites the framebuffer alpha, so the desktop shows
        # through the grid only, while every panel around the terminal
        # keeps its own opaque fill (requires a per-pixel-transparent
        # window — Sokol.run(transparent: true)).
        if (base_a = @theme.background.a) < 255
          p.rect_replace(rect, @theme.background)
        else
          p.rect(rect, fill: @theme.background)
        end

        offset = term.display_offset
        row_y = ->(r : Int32) { @grid_origin.y + r * @cell_h }

        # Background runs + selection overlay, then text runs, so text
        # stays readable over both.
        rows.times do |r|
          abs = grid.visible_index(offset, r)
          line = grid.lines[abs]?
          next unless line
          y = row_y.call(r)
          col = 0
          while col < cols
            cell = line[col]?
            break unless cell
            # REVERSE cells always paint a background: their effective
            # bg is the cell's FG (SGR 7 swaps the two), so without a
            # fill their glyphs would sit in the theme background color
            # on the theme background — invisible (bash's bracketed-
            # paste echo highlights the pasted text with \e[7m).
            if cell.bg.kind.default_bg? && !cell.attrs?(Cell::REVERSE) &&
               !term.selected?(abs, col)
              col += 1
              next
            end
            bg = effective_bg(cell)
            # Explicit cell backgrounds follow the theme background's
            # alpha (the terminal-opacity knob) instead of punching
            # opaque holes into a translucent terminal.
            if (base_a = @theme.background.a) < 255 && bg.a == 255
              bg = Color32.new(bg.r, bg.g, bg.b, base_a)
            end
            run = 1
            while col + run < cols && (c2 = line[col + run]?) &&
                  effective_bg(c2) == bg && !term.selected?(abs, col + run)
              run += 1
            end
            p.rect(Rect.from_min_size(
                     Pos2.new(@grid_origin.x + col * @cell_w, y),
                     Vec2.new(run * @cell_w, @cell_h)),
                   fill: bg)
            col += run
          end
          # selection overlay on top of backgrounds
          col = 0
          while col < cols
            if term.selected?(abs, col)
              run = 1
              while col + run < cols && term.selected?(abs, col + run)
                run += 1
              end
              p.rect(Rect.from_min_size(
                       Pos2.new(@grid_origin.x + col * @cell_w, y),
                       Vec2.new(run * @cell_w, @cell_h)),
                     fill: @theme.selection_overlay)
              col += run
            else
              col += 1
            end
          end
        end

        # Text runs: consecutive cells with equal style draw as one
        # string (monospace advances are uniform, so runs align).
        rows.times do |r|
          abs = grid.visible_index(offset, r)
          line = grid.lines[abs]?
          next unless line
          y = row_y.call(r) + @cell_h / 2
          col = 0
          while col < cols
            cell = line[col]?
            break unless cell
            if cell.blank? || cell.continuation? || cell.attrs?(Cell::INVISIBLE)
              col += 1
              next
            end
            style_key = {cell.fg, cell.flags}
            run = String.build do |io|
              c = col
              while c < cols && (cc = line[c]?)
                break if cc.blank? || cc.continuation? ||
                         cc.attrs?(Cell::INVISIBLE)
                break if cc.fg != style_key[0] || cc.flags != style_key[1]
                io << cc.char
                (cc.comb || [] of UInt32).each { |m| io << (m <= 0x10FFFF ? m.chr : '?') }
                c += 1
              end
            end
            color = effective_fg(cell)
            p.text(Pos2.new(@grid_origin.x + col * @cell_w, y),
                   run, @font_size, color)
            col += run.size
          end
        end

        paint_cursor(ui, rect, cols, rows)
        paint_scrollbar(ui)
        paint_exited(ui, rect) unless @backend.alive?
      end

      private def paint_cursor(ui : Ui, rect : Rect, cols : Int32, rows : Int32) : Nil
        term = @backend.term
        return unless term.cursor_visible && term.display_offset == 0
        return unless term.cursor_y < rows && term.cursor_x < cols
        # Blink phase (only when the option is on): the cursor is hidden
        # part of the cycle; with blinking off it is always drawn.
        return if @cursor_blinks && (ui.ctx.input.time % 1.06) >= 0.65
        x = @grid_origin.x + term.cursor_x * @cell_w
        y = @grid_origin.y + term.cursor_y * @cell_h
        color = @theme.cursor
        p = ui.painter
        case term.cursor_style
        in .block?
          p.rect(Rect.from_min_size(Pos2.new(x, y),
            Vec2.new(@cell_w, @cell_h)), fill: color)
        in .bar?
          p.rect(Rect.from_min_size(Pos2.new(x, y),
            Vec2.new(@cell_w / 4, @cell_h)), fill: color)
        in .underline?
          p.rect(Rect.from_min_size(Pos2.new(x, y + @cell_h - 2),
            Vec2.new(@cell_w, 2)), fill: color)
        end
      end

      private def paint_exited(ui : Ui, rect : Rect) : Nil
        p = ui.painter
        p.rect(rect, fill: Color32.new(0, 0, 0, 90))
        code = @backend.exit_code
        note = code.nil? ? "[process exited]" : "[process exited: #{code}]"
        p.text(Pos2.new(rect.center.x, rect.center.y), note,
               @font_size, Color32.new(255, 120, 120, 220))
      end

      # --- input ----------------------------------------------------------

      private def cell_at(pos : Pos2, cols : Int32, rows : Int32) : {Int32, Int32}
        term = @backend.term
        col = ((pos.x - @grid_origin.x) / @cell_w).floor.to_i.clamp(0, term.cols - 1)
        row = ((pos.y - @grid_origin.y) / @cell_h).floor.to_i.clamp(0, term.rows - 1)
        {row, col}
      end

      private def handle_pointer(ctx : Context, response : Response, rect : Rect) : Nil
        term = @backend.term
        input = ctx.input
        cols = term.cols
        rows = term.rows

        if input.pointer_pressed? && response.hovered?
          response.request_focus
          row, col = cell_at(input.pointer_pos.not_nil!, cols, rows)
          if term.mouse_mode.none?
            # Start a Simple selection: anchor at the pressed cell. The
            # gesture state lives in term.selection (the widget itself
            # is rebuilt every frame), and the drag frames below move
            # the head.
            abs = term.current_grid.visible_index(term.display_offset, row)
            term.selection = {Terminal::SelPoint.new(abs, col),
                              Terminal::SelPoint.new(abs, col)}
          else
            report_mouse(term, 0, true, row, col, input.modifiers)
          end
        elsif input.pointer_released?
          if term.mouse_mode.none?
            if response.hovered? &&
               (response.double_clicked? || response.triple_clicked?)
              # egui_term's Semantic/Lines selections: double-click a
              # word, triple-click the line.
              row, col = cell_at(input.pointer_pos.not_nil!, cols, rows)
              abs = term.current_grid.visible_index(term.display_offset, row)
              if response.triple_clicked?
                term.select_line(abs)
              else
                term.select_word(abs, col)
              end
            else
              # an empty selection (click without a drag) clears it
              sel = term.selection
              term.selection = nil if sel && sel[0] == sel[1]
            end
          elsif response.hovered?
            row, col = cell_at(input.pointer_pos.not_nil!, cols, rows)
            report_mouse(term, 0, false, row, col, input.modifiers)
          end
        elsif input.pointer_down? && response.hovered?
          if term.mouse_mode.none?
            # Move the selection head while the gesture belongs to this
            # terminal (press/drag verdict, not just the button state —
            # a hold that started on the scrollbar must not extend).
            if (sel = term.selection) &&
               (response.pressed? || response.dragged?)
              row, col = cell_at(input.pointer_pos.not_nil!, cols, rows)
              abs = term.current_grid.visible_index(term.display_offset, row)
              term.selection = {sel[0], Terminal::SelPoint.new(abs, col)}
            end
          elsif term.mouse_mode.motion? || term.mouse_mode.any?
            row, col = cell_at(input.pointer_pos.not_nil!, cols, rows)
            report_mouse(term, 32, true, row, col, input.modifiers)
          end
        end

        # Wheel: report to the child when it listens; otherwise scroll
        # the view (primary) or send arrows (alternate screen, what
        # less/vim expect).
        unless input.scroll.y.zero?
          lines = (input.scroll.y.abs / 40.0).ceil.to_i.clamp(1, 10)
          if term.mouse_mode.none?
            if term.alt_active?
              up = input.scroll.y > 0
              key = up ? KeyCode::Up : KeyCode::Down
              bytes = Keymap.encode(term, key, Modifiers.new, nil).not_nil!
              lines.times { @backend.write(bytes) }
            else
              term.scroll_display(input.scroll.y > 0 ? lines : -lines)
              ctx.request_repaint
            end
          elsif response.hovered?
            row, col = cell_at(input.pointer_pos.not_nil!, cols, rows)
            code = input.scroll.y > 0 ? 64 : 65
            report_mouse(term, code, true, row, col, input.modifiers)
          end
        end
      end

      private def report_mouse(term : Terminal, button : Int32, pressed : Bool,
                               row : Int32, col : Int32,
                               mods : Modifiers) : Nil
        code = button
        code += 4 if mods.shift
        code += 8 if mods.alt
        code += 16 if mods.ctrl
        if bytes = term.mouse_bytes(code, pressed, col, row)
          @backend.write(bytes)
        end
      end

      private def handle_keys(ctx : Context, response : Response) : Nil
        term = @backend.term
        input = ctx.input
        mods = input.modifiers

        # View-level shortcuts first.
        if mods.ctrl && mods.shift
          if input.consume_key(KeyCode::C)
            if (sel = term.selection_text)
              SystemPorts::Clipboard.text = sel
            end
            return
          end
          if input.consume_key(KeyCode::V)
            if (text = SystemPorts::Clipboard.text)
              @backend.write(term.paste_bytes(text))
            end
            return
          end
        end
        # Scrollback paging: Shift+PageUp/Down (the classic binding)
        # and Ctrl+Shift+PageUp/Down likewise; Shift+Home/End jump to
        # the oldest line / back to the live one.
        if mods.shift && !mods.alt
          if input.consume_key(KeyCode::PageUp)
            term.scroll_display(term.rows)
            return
          end
          if input.consume_key(KeyCode::PageDown)
            term.scroll_display(-term.rows)
            return
          end
          if mods.shift && input.consume_key(KeyCode::Home)
            term.scroll_display(term.grid.scrollback_used)
            return
          end
          if mods.shift && input.consume_key(KeyCode::End)
            term.scroll_display(-term.display_offset)
            return
          end
        end

        # Ctrl+C copies when something is selected and falls through
        # to the child (^C) otherwise (egui_term's Copy handling).
        if mods.ctrl && !mods.shift && !mods.alt &&
           input.key_pressed?(KeyCode::C) && (sel = term.selection_text)
          SystemPorts::Clipboard.text = sel
          input.consume_key(KeyCode::C)
          return
        end

        # Everything else belongs to the child. Consume every pressed
        # special key so other widgets don't double-act on it.
        handled_special = false
        KeyCode.each do |key|
          next unless input.key_pressed?(key)
          next unless special_key?(key)
          input.consume_key(key)
          if bytes = Keymap.encode(term, key, mods, nil)
            term.reset_scroll
            @backend.write(bytes)
          end
          handled_special = true
        end

        # Text input (printables): layout-correct chars, Alt as Meta.
        if !handled_special || input.text.size > 0
          if !input.text.empty? && !input.shortcut_modifiers_down?
            term.reset_scroll
            @backend.write(Keymap.encode(term, nil, mods, input.text) || input.text.to_slice)
          end
        end

        # Ctrl+letter with no text input (Ctrl+C, Ctrl+D, ...).
        if mods.ctrl && !mods.shift && !mods.alt
          KeyCode.each do |key|
            next unless input.key_pressed?(key)
            next unless key.value >= 65 && key.value <= 90
            input.consume_key(key)
            if bytes = Keymap.encode(term, key, mods, nil)
              term.reset_scroll
              @backend.write(bytes)
            end
          end
        end
      end

      private def special_key?(key : KeyCode) : Bool
        case key
        when .up?, .down?, .left?, .right?, .home?, .end?, .insert?,
             .delete?, .page_up?, .page_down?,
             .f1?, .f2?, .f3?, .f4?, .f5?, .f6?, .f7?, .f8?, .f9?,
             .f10?, .f11?, .f12?, .tab?, .enter?, .backspace?, .escape?
          true
        else
          false
        end
      end
    end

    # Reopen Egui::Ui (NOT Egui::Terminal::Ui) for the one-line entry.
    class ::Egui::Ui
      # One-line entry: draw and drive a full terminal.
      def terminal(backend : Terminal::Backend,
                   theme : Terminal::Theme = Terminal::Theme.new,
                   font_size : Float64 = 14.0,
                   cursor_blinks : Bool = false) : Response
        add(Terminal::TermView.new(backend, theme, font_size, cursor_blinks))
      end
    end
  end
end
