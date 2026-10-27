require "../../src/egui"

# FpsMeter — the FPS/frame-time meter, a stateless custom element:
# the top-level `widget` sugar registers it in the global registry
# every renderer sees. No class, no template file — that machinery is
# for stateful things like StatusBar. A moving meter needs moving
# frames, so the handler also drives the repaint.
# Rendered as <fps_meter/> (see assets/notepad.exml).

widget :fps_meter do |node, ui, ctx, rt, renderer|
  ctx.request_repaint
  ui.label("FPS: #{"%.1f" % ctx.fps}  (frame #{"%.1f" % (ctx.input.dt * 1000)} ms)")
end
