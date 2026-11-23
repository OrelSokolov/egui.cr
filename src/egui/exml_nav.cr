# exml_nav.cr — page transitions for the exml navigation pattern
# (velour-components.md, этап 6). The `nav=`/`back=` pages of the
# ios_settings shape live in store slots (`strings["page"]`); the
# switch itself is instant — this orchestrator turns it into a slide
# push/pop driven by the engine springs (src/egui/spring.cr).
#
#   nav = Egui::Exml::Nav.new(rt, slot: "page")
#
#   def update(ctx)          # each frame, BEFORE rendering
#     nav.update(ctx)        # detects the slot change, drives the spring
#   end
#
#   # in the screen handler: while nav.transitioning?, render BOTH
#   # bodies — the outgoing one offset by nav.offset_out(width), the
#   # incoming one by nav.offset_in(width); settled frames use
#   # nav.offset_in == 0 and render the current page only.
#
# Duration/easing are the spring's `response`/`damping` (the same
# vocabulary as the ECSS `transition: spring(...)` spec). The DEFAULT
# is no animation: a plain slot switch renders instantly — the
# transition exists only where an app constructs a Nav and calls
# #update.
#
# Offsets are symmetric in progress: the spring tracks 0→1 on push and
# 1→0 on pop, so the SAME formulas produce the correct slide for both
# directions — the entering page comes from the right, the leaving one
# exits left; on pop the spring runs backwards and both move the other
# way (iOS UINavigationController semantics).

module Egui
  module Exml
    class Nav
      enum Direction
        Push
        Pop
      end

      getter current : String
      getter previous : String? = nil
      getter progress : Float64 = 1.0
      getter direction : Direction = Direction::Push

      @spring = Spring.new(1.0)
      @response : Float64
      @damping : Float64

      # Watches `slot` (a strings slot; `root` is its resting value —
      # a switch back to it is a pop, anything else a push).
      def initialize(@rt : Runtime, @slot : String = "page",
                     @root : String = "root", response : Float64 = 0.3,
                     damping : Float64 = 1.0)
        initial = @rt.string(@slot)
        @current = initial.empty? ? @root : initial
        @response = response
        @damping = damping
      end

      def transitioning? : Bool
        !@previous.nil?
      end

      # Each frame before rendering: detect the slot change, seed the
      # spring, step it, and buy the frames the flight needs (the
      # dirty auto-repaint of этап 3 covers writes, not a running
      # spring).
      def update(ctx : Context) : Nil
        page = @rt.string(@slot)
        page = @root if page.empty?
        if page != @current
          if @previous.nil?
            @previous = @current
            @direction = page == @root ? Direction::Pop : Direction::Push
            @spring.set(@direction.push? ? 0.0 : 1.0)
          else
            # retarget mid-flight: keep the oldest page as `previous`,
            # flip the direction — and mirror the progress so the same
            # formulas keep pointing the slide the right way (velocity
            # continuity through Spring, no jump)
            @direction = page == @root ? Direction::Pop : Direction::Push
            @spring.value = 1.0 - @spring.value
          end
          @current = page
          ctx.request_repaint
        end
        if @previous
          target = @direction.push? ? 1.0 : 0.0
          @progress = @spring.track(ctx.input.dt, target, @response,
            @damping)
          if @spring.moving?(target)
            ctx.request_repaint
          else
            @previous = nil
          end
        else
          @progress = 1.0
        end
      end

      # Settled: no transition — render the current page only.
      def settled? : Bool
        @previous.nil?
      end

      # Pixel offsets of the entering (current) and leaving (previous)
      # bodies at the given viewport width: {offset_in, offset_out}.
      # {0.0, 0.0} when settled.
      def offsets(width : Float64) : {Float64, Float64}
        return {0.0, 0.0} unless @previous
        {(1.0 - @progress) * width, -@progress * width}
      end
    end
  end
end
