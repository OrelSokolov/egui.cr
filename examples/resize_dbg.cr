# Resize diagnostics: every frame prints and shows the LIVE sokol
# window size (LibEguiCr.sapp_width/height, read mid-frame on the render
# thread's clock) against the size THIS frame was produced for
# (ctx.input.screen_rect). When they disagree the labels turn red — a
# frame is being rendered for a size the window no longer has.
#
# The env below also arms the shim-side check (EGUI_RESIZE_DBG=1,
# backend/sokol_shim.c sh_resize_dbg_check): at PRESENT time the render
# thread paints the unbacked strip — the pixels a compositor flashes
# black during an expanding resize — RED and logs both sizes per tick.
# Red flash at the trailing edge while dragging = exactly the frame that
# used to show the black band.

ENV["EGUI_RESIZE_DBG"] = "1"

require "../src/egui/driver_selector"

class ResizeDbgApp < Egui::App
  T0 = Time.instant

  def update(ctx : Egui::Context) : Nil
    # Live window size (pixels) vs this frame's production size.
    win_w = LibEguiCr.sapp_width
    win_h = LibEguiCr.sapp_height
    ppp = ctx.pixels_per_point
    screen = ctx.input.screen_rect
    ren_w = (screen.width * ppp).round.to_i
    ren_h = (screen.height * ppp).round.to_i
    match = win_w == ren_w && win_h == ren_h
    color = match ? Egui::Color32.new(64, 200, 96, 255)
                  : Egui::Color32.new(235, 50, 50, 255)

    dt_s = (Time.instant - T0).total_seconds
    puts "[frame %10.3f] window #{win_w}x#{win_h}  render #{ren_w}x#{ren_h}" \
         "#{match ? "" : "  MISMATCH"}" % dt_s

    ctx.request_repaint # keep the per-frame print flowing
    ctx.central_panel do |ui|
      # Big FPS meter: dips during a resize show the A→R roundtrip cost
      # (the compositor throttles the window step to our present rate —
      # a present stall or slow produce reads here as sagging FPS).
      fps = ctx.fps
      fps_color = fps >= 55 ? Egui::Color32.new(64, 200, 96, 255)
                            : Egui::Color32.new(235, 50, 50, 255)
      ui.rich(Egui::RichText.new("FPS #{"%.1f" % fps}")
        .color(fps_color).size(48.0))
      ui.rich(Egui::RichText.new("frame #{"%.1f" % (ctx.input.dt * 1000)} ms")
        .color(fps_color).size(20.0))
      ui.heading("Resize diagnostics")
      ui.separator
      ui.rich(Egui::RichText.new("window (live): #{win_w} x #{win_h}")
        .color(color).size(22.0))
      ui.rich(Egui::RichText.new("render (this frame): #{ren_w} x #{ren_h}")
        .color(color).size(22.0))
      ui.separator
      if match
        ui.label("in sync")
      else
        ui.rich(Egui::RichText.new("MISMATCH — rendering a stale size").color(color))
      end
      ui.separator
      ui.label("Drag the window edge: a RED strip at the trailing edge marks")
      ui.label("the exact pixels the compositor would otherwise flash black")
      ui.label("(shim log: [rsz] lines; [sync] hold/release = WM throttle).")
    end
  end
end

Egui.run(ResizeDbgApp.new, title: "egui-cr — resize dbg")
