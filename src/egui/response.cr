# Port of egui's Response (response.rs): what every widget returns —
# id/rect/sense plus this frame's interaction verdicts and focus state.
# Everything here is derived per frame; nothing is stored.

module Egui
  class Response
    getter ctx : Context
    getter id : Id
    getter rect : Rect
    getter sense : Sense
    getter? hovered : Bool
    getter? clicked : Bool
    getter click_count : Int32
    getter? pressed : Bool
    getter? active : Bool
    getter? dragged : Bool
    getter? drag_started : Bool
    getter? drag_stopped : Bool
    getter drag_delta : Vec2
    # egui `Response::changed` (response.rs): set by stateful widgets
    # (checkbox, slider, …) when the underlying data changed this frame.
    @changed : Bool
    # Value widgets (Slider, DragValue) publish their freshly computed
    # value here so the Ui block-form helpers can hand it back to the
    # app (`ui.slider(v, range) { |new_v| … }`).
    property widget_value : Float64?
    # Text widgets (TextEdit) publish the edited buffer the same way
    # (`ui.text_edit_singleline(buf) { |new| … }`).
    property widget_text : String?
    # Color widgets (ColorPicker) publish the picked color
    # (`ui.color_edit32(color) { |c| … }`).
    property widget_color : Color32?

    def initialize(@ctx : Context, @id : Id, @rect : Rect, @sense : Sense,
                   @hovered : Bool, @clicked : Bool, @click_count : Int32,
                   @pressed : Bool, @active : Bool, @dragged : Bool,
                   @drag_started : Bool, @drag_stopped : Bool,
                   @drag_delta : Vec2, @changed : Bool = false)
    end

    def changed? : Bool
      @changed
    end

    # egui `Response::mark_changed` — widgets call this after mutating
    # the value they view.
    def mark_changed : Nil
      @changed = true
    end

    def clicked(&block : self ->) : self
      yield self if @clicked
      self
    end

    def dragged(&block : self ->) : self
      yield self if @dragged
      self
    end

    def hovered(&block : self ->) : self
      yield self if @hovered
      self
    end

    def double_clicked? : Bool
      @clicked && @click_count == 2
    end

    def triple_clicked? : Bool
      @clicked && @click_count == 3
    end

    # --- focus (egui Response::has_focus / lost_focus / gained_focus) ---

    def has_focus? : Bool
      @ctx.memory.focus.has_focus?(@id)
    end

    def gained_focus? : Bool
      @ctx.memory.focus.gained_focus?(@id)
    end

    def lost_focus? : Bool
      @ctx.memory.focus.lost_focus?(@id)
    end

    def request_focus : Nil
      @ctx.memory.focus.request(@id)
    end

    # egui focus highlight: a ring around the focused widget (upstream
    # draws it in the widget's own stroke; a dedicated ring is simpler
    # here). Widgets call this right after painting themselves.
    def paint_focus_ring(rounding : Float64 = 4.0) : Nil
      return unless has_focus?
      @ctx.painter.rect(@rect.expand(2.0), rounding, nil,
        @ctx.style.visuals.selection_fill, 2.0)
    end

    def on_hover_text(text : String) : self
      show_tooltip(text) if hovered?
      self
    end

    # egui `Response::on_hover_cursor` — when hovered, use this icon
    # for the mouse cursor.
    def on_hover_cursor(cursor : CursorIcon) : self
      @ctx.set_cursor_icon(cursor) if hovered?
      self
    end

    # egui `Response::on_hover_and_drag_cursor` — same, but also while
    # dragging (sliders, resize grips).
    def on_hover_and_drag_cursor(cursor : CursorIcon) : self
      @ctx.set_cursor_icon(cursor) if hovered? || dragged?
      self
    end

    # egui tooltip (containers/tooltip.rs): appears in the Tooltip
    # layer at the pointer + offset, after the widget has been hovered
    # for a short delay (hover-start time is per-widget system state).
    TOOLTIP_DELAY = 0.5

    private def show_tooltip(text : String) : Nil
      painter = @ctx.painter
      memory = @ctx.memory
      now = @ctx.input.time

      start_key = @id
      unless (start = memory.tooltip_starts[start_key]?) && start > 0.0
        memory.tooltip_starts[start_key] = now
        @ctx.request_repaint
        return
      end
      return if now - start < TOOLTIP_DELAY

      style = @ctx.style
      font_size = style.font_size * 0.9
      text_size = @ctx.fonts.measure(text, font_size)
      margin = Vec2.new(6.0, 4.0)
      pos = @ctx.input.pointer_pos.not_nil! + Vec2.new(16.0, 16.0)

      painter.layer = Order::Tooltip
      painter.clip = Rect.from_min_size(pos, text_size + margin * 2.0)
      painter.rect(Rect.from_min_size(pos, text_size + margin * 2.0), 4.0,
        style.visuals.window_fill, style.visuals.window_stroke, 1.0)
      painter.text(pos + margin, text, font_size, style.visuals.text_color)
      painter.layer = Order::Background
      painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end
  end
end
