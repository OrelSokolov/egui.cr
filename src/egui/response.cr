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

    def on_hover_text(text : String) : self
      # Tooltips come with the tooltip layer (slice 2+); no-op for now,
      # kept so app code can be written egui-1:1 already.
      self
    end
  end
end
