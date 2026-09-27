# egui-cr: borderless window demo — the DEFAULT client-side chrome.
#
# `Egui::Backend::Sokol.run(decorations: false)` strips the system
# frame; the backend then draws `Egui::WindowFrame` before every app
# frame, in one of three looks (segmented switch below):
#
#   * Windows 11 dark — #202020 caption, square caption buttons,
#     #C42B1C close hover, hairline window outline;
#   * Windows XP (Luna) — blue gradient titlebar, glossy rounded
#     caption buttons with a red close, and a thick 4pt blue frame
#     around the client area;
#   * Ubuntu (classic Ambiance) — gradient titlebar, centered title,
#     round buttons at the right edge, close in Ubuntu orange;
#   * macOS — light titlebar with a separator hairline, traffic lights
#     at the LEFT edge (close, minimize, zoom).
#
# Drag the caption to move, double-click it to maximize, drag any
# window edge to resize — all handled by the frame. The decorations can
# be toggled back at runtime through the Window port (checkbox below) —
# the client-side frame hides and reappears in step with the system
# frame. `chrome: false` in #run would opt out for fully hand-rolled
# chrome (see git history for the old manual version).

require "../src/egui"
require "../src/egui/backend/sokol"

class BorderlessApp < Egui::App
  STYLES = {Egui::WindowFrame::Style::Windows,
            Egui::WindowFrame::Style::WindowsXp,
            Egui::WindowFrame::Style::Ubuntu,
            Egui::WindowFrame::Style::Macos}
  STYLE_LABELS = ["Windows 11", "Windows XP", "Ubuntu", "macOS"]

  @decorated = false
  @style_index = 0

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("Borderless window")
      ui.label("The caption above is Egui::WindowFrame, drawn by the " \
               "backend because decorations are off. Switch the look:")

      ui.segmented(@style_index, STYLE_LABELS) do |i|
        @style_index = i
        Egui::Backend::Sokol.chrome_style = STYLES[i]
      end

      ui.label("Drag the caption to move, double-click it to maximize, " \
               "drag any window edge to resize.")

      resp = ui.checkbox(@decorated, "System decorations (runtime toggle)")
      if resp.changed?
        @decorated = !@decorated
        Egui::SystemPorts::Window.set_decorations(@decorated)
      end

      if ui.button("Minimize").clicked?
        Egui::SystemPorts::Window.minimize
      end
      if ui.button("Quit").clicked?
        Egui::SystemPorts::Quit.quit!
      end

      if (pos = Egui::SystemPorts::Window.position)
        scale = Egui::SystemPorts::Screen.dpi_scale
        screen = ctx.input.screen_rect
        ui.label("window @ (#{"%.0f" % pos.x}, #{"%.0f" % pos.y}) px, " \
                 "#{"%.0f" % screen.width}×#{"%.0f" % screen.height} pt, " \
                 "dpi #{"%.1f" % scale}")
      end
    end
  end
end

Egui::Backend::Sokol.run(BorderlessApp.new,
  title: "egui-cr — borderless", decorations: false)
