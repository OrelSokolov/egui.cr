# egui-cr reactive demo — signals, computeds and bound widgets.
#
# Three things to watch:
#  - `ticks` advances from a background fiber once a second, with no
#    `request_repaint` anywhere — the reactive setter wakes the frame
#    (on-demand repaint) by itself;
#  - `greeting` is a `computed`: its block runs only when `name`
#    changes — the run counter in the bottom panel stays flat while
#    you drag the slider or wait for ticks;
#  - every input is a binding: `ui.text_field(name)`, `ui.slider(speed…)`,
#    `ui.checkbox(enabled…)` — no `if changed?; @field = v` plumbing.

require "../src/egui"
require "../src/egui/backend/sokol"

class CounterApp < Egui::App
  reactive count = 0
  reactive ticks = 0
  reactive name = "мир"
  reactive speed = 0.3
  reactive enabled = true

  # Memoization probes for the bottom panel.
  class_property greeting_runs = 0
  class_property total_runs = 0

  computed greeting : String = begin
    CounterApp.greeting_runs += 1
    "Привет, #{name}!"
  end

  # computed-of-computed: total → count + ticks.
  computed total : Int32 = begin
    CounterApp.total_runs += 1
    count + ticks
  end

  def initialize
    super
    # A second-beat fiber: writes the signal from outside the frame
    # loop — the reactive setter requests the repaint for us.
    spawn do
      loop do
        sleep 1.second
        self.ticks += 1
      end
    end
  end

  def update(ctx : Egui::Context) : Nil
    ctx.window("Reactive", Egui::Pos2.new(40.0, 40.0), width: 420.0) do |ui|
      ui.heading(greeting)
      ui.text_field(name_signal, hint: "как вас зовут?")

      ui.separator
      ui.label("count: #{count}   ticks: #{ticks}   total: #{total}")
      self.count += 1 if ui.button("+1 по кнопке").clicked?

      ui.slider(speed_signal, 0.0..1.0, text: "speed")
      ui.checkbox(enabled_signal, "Включено")
    end

    ctx.bottom_panel("stats") do |ui|
      ui.label(
        "greeting computed: #{CounterApp.greeting_runs} runs, " \
        "total computed: #{CounterApp.total_runs} runs   " \
        "FPS: #{"%.1f" % ctx.fps}"
      )
    end
  end
end

Egui::Backend::Sokol.run(CounterApp.new, title: "egui-cr — reactive",
  inspector: :hidden)
