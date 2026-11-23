# Mobile PIN / OTP input (Material `PinInput`, iOS one-time-code field)
# — plans/todo/mobile_widgets.md #19.
#
# N cells (4 by default, 4..6 being the usual OTP lengths) over ONE
# buffer: the app owns a single `text` string and the widget derives
# everything else. The cells are visual — one FOCUSABLE interact per
# cell (that is what puts the existing focus machinery to work):
#
# * clicking a cell focuses it (the caret cell = min(cell, buffer
#   size), so clicking past the filled prefix lands at its end);
# * while focused, digits overwrite/append at the caret cell and the
#   focus AUTO-ADVANCES to the next cell — the focus id itself is the
#   cell's child id (`id.child(i + 1)`), so the dead-man's switch keeps
#   it alive exactly as long as the widget keeps drawing that cell
#   (upstream focusable keep-alive, see Memory#interact);
# * filling the LAST cell completes the PIN: the focus is dropped
#   (down goes the on-screen keyboard on touch platforms —
#   `Focus#text_input!` is claimed while focused, so the drop rides the
#   same machinery) and the sugar reports the completion;
# * Backspace deletes backward and pulls the focus back with it;
#   Escape surrenders the focus without editing.
#
# Digits only (`numeric: true` default) — the PIN/OTP case; non-digit
# keystrokes are silently ignored, paste is NOT implemented in v1 (no
# clipboard shell around the cells — noted limitation, the plain
# TextEdit covers paste-bearing fields).
#
# Reporting: `Response#changed?` on every edit, `Response#widget_text`
# = the new buffer. The widget also exposes `buffer`/`filled?` so the
# `ui.pin_input` sugar can fire its block with the pair
# (new buffer, completed?).
#
# Styling — the `pin_input` class: `cell_size` (44), `gap` (8),
# `rounding` (8), `fill`, `stroke`, `focus_stroke`, `text_color`.

module Egui
  class PinInput
    include Widget

    # Memory-cell seed for the caret position (0..count, clamped to the
    # buffer size on entry).
    POS_SEED = 0x9055_u64

    def initialize(@text : String, @count : Int32 = 4,
                   @numeric : Bool = true, id : String? = nil)
      @id_name = id
      @buffer = @text
      @filled = @text.size >= @count
    end

    # The buffer as of the last #ui run (the incoming text when no edit
    # happened) and whether it has reached `count` — read back by the
    # Ui sugar and by block-free callers.
    getter buffer : String
    getter? filled : Bool

    def style_class : String?
      "pin_input"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("cell_size", :number, min: 0.0),
        StyleProp.new("gap", :number, min: 0.0),
        StyleProp.new("rounding", :number, min: 0.0),
        StyleProp.new("fill", :color),
        StyleProp.new("stroke", :color, states: true),
        StyleProp.new("focus_stroke", :color),
        StyleProp.new("text_color", :color),
      ]
    end

    def inspector_label : String?
      @buffer
    end

    # The focus id of caret cell `i` (`i` in 0...count). Public so a
    # spec (or a test harness) can address cells the same way the
    # widget does.
    def cell_id(base : Id, i : Int32) : Id
      base.child((i + 1).to_u64)
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      class_vars = style_vars(ui, id)
      style = effective_style(ui, id, class_vars)
      focus = ui.ctx.memory.focus

      cell = class_vars.f64("cell_size", 44.0)
      gap = class_vars.f64("gap", 8.0)
      natural = Vec2.new(@count * cell + (@count - 1) * gap, cell)
      size = styled_size(natural, class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click)

      # Caret position: memory cell keyed by the widget id, defaulting
      # to the end of the buffer (the natural first-focus position).
      pos_id = id.child(POS_SEED)
      ui.ctx.memory.use_id(pos_id)
      pos = ui.ctx.memory.data.get_int(pos_id, @text.size)
                       .clamp(0, @text.size).clamp(0, @count)

      # One interact per cell (Focusable): registers the cells for the
      # dead-man's switch, hands clicks to the focus system, and keeps
      # the CURRENTLY focused cell alive without extra plumbing.
      cells = [] of Response
      @count.times do |i|
        cell_rect = Rect.from_min_size(
          Pos2.new(rect.left + i * (cell + gap), rect.top),
          Vec2.new(cell, size.y))
        cells << ui.interact(cell_rect, cell_id(id, i),
          Sense.click | Sense::Focusable)
      end

      # A click on a cell focuses it (clamped to the filled prefix —
      # you cannot park the caret past the end). The click verdict
      # lives on the CELL interact: the memory classifies one click id
      # per frame and the cells register AFTER the whole-rect interact,
      # so the cell wins it.
      if (clicked = cells.index(&.clicked?))
        pos = {clicked, @text.size}.min
        ui.ctx.memory.data.set_int(pos_id, pos)
        focus.request(cell_id(id, pos))
      end

      new_text = @text
      changed = false
      focused = (0...@count).any? { |i| focus.has_focus?(cell_id(id, i)) }

      # Keyboard BEFORE paint: an edit made this frame must show this
      # frame (the TextEdit ordering, for the same jitter-free reason).
      if focused
        focus.text_input! # raise the on-screen keyboard on touch
        ui.ctx.request_repaint # caret redraw while focused
        input = ui.ctx.input
        if input.consume_key(KeyCode::Escape)
          focus.clear
        else
          # Backspace first (a frame may carry backspace AND text).
          if (bs = input.consume_key_count(KeyCode::Backspace)) > 0
            bs.times do
              next unless pos > 0
              pos -= 1
              if pos < new_text.size
                new_text = new_text[0...pos] + new_text[(pos + 1)..]
              end
              changed = true
            end
          end
          # Typed characters: digits only by default; each fills the
          # caret cell (overwrite when inside the buffer, append at its
          # end) and advances the caret — the auto-advance IS the focus
          # request below.
          input.text.each_char do |ch|
            next if @numeric && !ch.number?
            break if pos >= @count
            if pos == new_text.size
              new_text += ch
            else
              new_text = new_text[0...pos] + ch + new_text[(pos + 1)..]
            end
            pos += 1
            changed = true
          end
          # Advance to the next cell, or drop focus when the PIN is
          # full (completion = the keyboard has no reason to stay up).
          if pos >= @count
            focus.clear
          else
            focus.request(cell_id(id, pos))
          end
        end
        ui.ctx.memory.data.set_int(pos_id, pos)
      end

      # Paint the cells: box per cell, filled digit for the buffer
      # prefix, caret line in the caret cell while focused.
      visuals = style.visuals
      fonts, family, bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      fill = class_vars.color("fill", visuals.window_fill)
      stroke = class_vars.color("stroke", visuals.window_stroke)
      focus_stroke = class_vars.color("focus_stroke", visuals.selection_fill)
      text_color = class_vars.color("text_color", visuals.text_color)
      rounding = class_vars.f64("rounding", 8.0)
      font_size = style.font_size * 1.4
      cell_w = cell * (size.x / natural.x) # styled width may rescale rows
      @count.times do |i|
        cell_rect = Rect.from_min_size(
          Pos2.new(rect.left + i * (cell_w + gap), rect.top),
          Vec2.new(cell_w, size.y))
        is_caret = focused && i == pos
        ui.painter.rect(cell_rect, rounding, fill,
          is_caret ? focus_stroke : stroke, is_caret ? 2.0 : 1.0)
        if i < new_text.size
          glyph = new_text[i].to_s
          w = fonts.measure(glyph, font_size).x
          ui.painter.text(
            Pos2.new(cell_rect.center.x - w / 2.0, cell_rect.center.y),
            glyph, font_size, text_color, family: family, bold: bold)
        elsif is_caret
          ui.painter.line(
            Pos2.new(cell_rect.center.x, cell_rect.center.y - font_size * 0.5),
            Pos2.new(cell_rect.center.x, cell_rect.center.y + font_size * 0.5),
            1.5, focus_stroke)
        end
      end

      @buffer = new_text
      @filled = new_text.size >= @count
      if changed
        response.widget_text = new_text
        response.mark_changed
      end
      response
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.pin_input(code, count: 6) { |new_text, filled| … }` — the block
  # fires on every edit; `filled` flips true when the last cell went
  # in (submit your OTP there).
  def pin_input(text : String, count : Int32 = 4,
                id : String? = nil,
                &on_change : (String, Bool) ->) : Response
    w = PinInput.new(text, count: count, id: id)
    response = add(w)
    on_change.call(w.buffer, w.filled?) if response.changed?
    response
  end

  def pin_input(text : String, count : Int32 = 4,
                id : String? = nil) : Response
    add(PinInput.new(text, count: count, id: id))
  end
end
