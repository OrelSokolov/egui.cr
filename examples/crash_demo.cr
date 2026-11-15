# crash_demo — deliberate crash probe for the engine's CrashReport
# window (egui/crash_report.cr). Two ways to die:
#
# * `--startup` divides by zero in the constructor, BEFORE any window
#   exists — the at_exit hook (driver_selector.cr) then boots the
#   standalone report window; this is the "launched from a file
#   manager, no console" scenario.
# * The button divides by zero inside `update`, mid-frame — the
#   driver's run_update rescue swaps the crashed update for the report
#   and keeps the loop running (scroll/select/copy work).
#
# Build: rake build:dev[crash_demo]

require "../src/egui/driver_selector"

class CrashDemo < Egui::App
  @boom : Int32?

  def initialize
    super()
    if ARGV.includes?("--startup")
      denominator = 0
      @boom = 1 // denominator
    end
  end

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("Crash demo")
      ui.label("This app exists to crash: it exercises the engine's " \
               "built-in crash report window.", wrap: true)
      ui.separator
      if ui.button("Divide by zero in update").clicked?
        denominator = 0
        @boom = 1 // denominator
      end
      ui.label("no crash yet — click the button, or relaunch with " \
               "--startup to die before the window opens", wrap: true)
    end
  end
end

Egui.run(CrashDemo.new, title: "egui-cr — crash demo",
  width: 640, height: 420)
