# The Wizard component demo — a Windows-wizard-style setup flow:
# banner header, body, footer navigation. Colors follow the active
# theme; only the LAYOUT is the classic wizard template.
#
#   bin/wizard

require "../src/egui/backend_selector"

class WizardApp < Egui::App
  @open = true
  @result = ""
  @typical = true
  @agree = false
  @run_after = false
  @wizard : Egui::Wizard

  def initialize
    super

    welcome = Egui::WizardStep.new("Welcome to the Setup Wizard",
      "This wizard walks through the egui.cr Wizard component.") do |ui|
      ui.label("Every page is a WizardStep template:")
      ui.label("  • title + subtitle render into the banner,")
      ui.label("  • the body block draws any widgets here,")
      ui.label("  • the footer buttons and their actions are parameters.")
    end
    # The watermark column: an Svg (DPI-crisp vector) or a raster file.
    welcome.side_image = Egui::SideImage.new(
      Egui::Svg.load("assets/icon.svg"))

    options = Egui::WizardStep.new("Installation options",
      "Choose where the demo takes you.") do |ui|
      if ui.radio(@typical, "Typical (Next enabled)").clicked?
        @typical = true
      end
      if ui.radio(!@typical, "Custom (Next gated until checked)").clicked?
        @typical = false
      end
      ui.allocate_space(Egui::Vec2.new(0.0, 8.0))
      if @typical
        ui.label("can_next is open — press Next.")
      else
        if ui.checkbox(@agree, "I accept this gate (enables Next)").clicked?
          @agree = !@agree
        end
      end
    end
    options.can_next { |_w| @typical || @agree }
    options.on_next { |_w| @result = "options accepted" }

    progress = Egui::WizardStep.new("Installing",
      "A fake long-running step — custom footer buttons.") do |ui|
      ui.label(@result.empty? ? "Nothing installed yet." : @result)
      ui.allocate_space(Egui::Vec2.new(0.0, 8.0))
      ui.label("This step replaces the footer wholesale:")
      ui.label("a custom action button plus Next, Cancel hidden.")
    end
    progress.show_cancel = false
    progress.next_label = "Install"
    progress.buttons = [
      Egui::Wizard::Button.custom("Pretend to install") do |_w|
        @result = "installed (demo)"
      end,
      Egui::Wizard::Button.next,
    ]

    done = Egui::WizardStep.new("Completing the Setup Wizard",
      "The last step's Next turns into Finish automatically.") do |ui|
      ui.label(@result)
      if ui.checkbox(@run_after, "Run the demo again after finishing").clicked?
        @run_after = !@run_after
      end
    end
    done.side_image = Egui::SideImage.from_file("assets/splash.png")
    done.on_show { |_w| @result = "finishing — #{@result}" }

    @wizard = Egui::Wizard.new("egui.cr Wizard Demo",
      [welcome, options, progress, done])
  end

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("Wizard demo")
      state = @open ? "open" : (@wizard.finished? ? "finished" : "cancelled")
      ui.label("Wizard #{state}.")
      if ui.button("Reopen").clicked?
        @wizard.reset!
        @open = true
      end
    end
    if @open
      @open = false if @wizard.show(ctx)
      if @wizard.finished? && @run_after
        @wizard.reset!
        @open = true
        @run_after = false
      end
    end
  end
end

Egui.run(WizardApp.new,
  title: "egui.cr — Wizard demo",
  width: 900, height: 640, inspector: :hidden)
