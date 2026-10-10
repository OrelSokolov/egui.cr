# egui-cr: borderless window demo — the DEFAULT client-side chrome.
#
# `Egui.run(decorations: false)` strips the system
# frame; the backend then draws `Egui::WindowFrame` before every app
# frame, in one of three looks (segmented switch below):
#
#   * Windows 11 dark — #202020 caption, square caption buttons,
#     #C42B1C close hover, hairline window outline;
#   * Windows XP (Luna) — blue gradient titlebar, glossy rounded
#     caption buttons with a red close, and a thick 4pt blue frame
#     around the client area (plus a Silver variant — same chrome in
#     silver-grey with a rose #DFA1A6→#913448 close button);
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

require "../src/egui/backend_selector"

class BorderlessApp < Egui::App
  STYLES = {Egui::WindowFrame::Style::Windows,
            Egui::WindowFrame::Style::WindowsXp,
            Egui::WindowFrame::Style::WindowsXpSilver,
            Egui::WindowFrame::Style::Ubuntu,
            Egui::WindowFrame::Style::Macos}
  STYLE_LABELS = ["Windows 11", "Windows XP", "Windows XP Silver", "Ubuntu",
                  "macOS"]

  @decorated = false
  # `--frame windows|xp|ubuntu|macos` — the initial look (screenshots).
  # Parsed as a CLASS method because the style must reach `Egui.run`'s
  # `chrome_style:` option: run assigns @@chrome_style AFTER the app is
  # constructed, so an assignment from #initialize would be overwritten
  # before the first frame (only the in-app segmented switch worked).
  @style_index = BorderlessApp.frame_arg

  def self.frame_arg : Int32
    frame = ARGV.each_cons(2).find { |pair| pair[0] == "--frame" }
                       .try(&.[](1)) ||
               ARGV.find { |a| a.starts_with?("--frame=") }
                 .try(&.split('=', 2)[1]) || "windows"
    case frame.downcase
    when "xp"                then 1
    when "xpsilver", "silver" then 2
    when "ubuntu"            then 3
    when "macos"             then 4
    else                          0
    end
  end

  def self.frame_style : Egui::WindowFrame::Style
    STYLES[frame_arg]
  end

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

Egui.run(BorderlessApp.new,
  title: "egui-cr — borderless", decorations: false, inspector: :hidden,
  chrome_style: BorderlessApp.frame_style)
