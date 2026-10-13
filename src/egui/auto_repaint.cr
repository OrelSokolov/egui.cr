# Auto-repaint for widgets whose content changes OUTSIDE the input
# stream — canvases fed by audio meters, PTY output, video decoders,
# live plots. The backend paints on demand: without a repaint request
# new content sits invisible until the next mouse event (the classic
# "animation only runs while I wave the mouse" bug).
#
#   class WaveView
#     include Egui::AutoRepaint
#
#     def push(samples)
#       draw(samples)
#       auto_repaint! # content changed — grant a frame to show it
#     end
#
#     def show(ui)
#       pump_auto_repaint(ui.ctx) # paint-path half, every frame
#       ...
#     end
#   end
#
# Contract: call #auto_repaint! after any change the user should see,
# and #pump_auto_repaint(ctx) from the widget's paint path. The pump
# hands the module a Context, so later changes request frames on their
# own — even between frames from another fiber (Context#request_repaint
# wakes a sleeping loop itself). While changes keep arriving the loop
# runs at vsync; the moment they stop, frames stop too, so an idle
# widget costs nothing. Plain OS threads should only set their own
# flag and call #auto_repaint! from a fiber (request paths are not
# cross-thread safe).
module Egui
  module AutoRepaint
    @auto_repaint_ctx : Context? = nil
    @auto_repaint_pending : Bool = false

    # Content changed: make sure a frame runs to show it. Safe any
    # time — inside a frame, between frames, from another fiber.
    protected def auto_repaint! : Nil
      if (ctx = @auto_repaint_ctx)
        ctx.request_repaint
      else
        # No Context yet (before the first show): remembered and
        # consumed by the first #pump_auto_repaint.
        @auto_repaint_pending = true
      end
    end

    # Paint-path half: remember the Context for later #auto_repaint!
    # calls, and consume a pre-first-show change.
    protected def pump_auto_repaint(ctx : Context) : Nil
      @auto_repaint_ctx = ctx
      if @auto_repaint_pending
        @auto_repaint_pending = false
        ctx.request_repaint
      end
    end
  end
end
