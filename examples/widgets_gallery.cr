# egui-cr widget gallery — phase 1 + phase 2 widgets in one app.

require "../src/egui"
require "../src/egui/backend/sokol"

class GalleryApp < Egui::App
  @checked = false
  @radio : Int32 = 1
  @slider = 0.3_f64
  @drag = 10.0_f64
  @combo = "Second"
  @modal_open = false

  COMBO_OPTIONS = ["First", "Second", "Third"]

  def update(ctx : Egui::Context) : Nil
    # Desktop-style menu bar pinned to the top.
    ctx.menu_bar do |bar|
      bar.menu_button("File") do |menu|
        menu.menu_item("New", "Ctrl+N") { }
        menu.menu_item("Open…", "Ctrl+O") { }
        menu.menu_item("Quit", "Ctrl+Q") { }
      end
      bar.menu_button("Edit") do |menu|
        menu.menu_item("Undo", "Ctrl+Z") { }
        menu.menu_item("Redo", "Ctrl+Shift+Z") { }
      end
      bar.menu_button("View") do |menu|
        menu.menu_item("Toggle modal") { @modal_open = true }
      end
    end

    ctx.window("Widget Gallery", Egui::Pos2.new(24.0, 60.0), width: 440.0) do |ui|
      ui.heading("Simple widgets")
      ui.checkbox(@checked, "Checkbox (#{@checked})") { |v| @checked = v }
      ui.separator

      ui.horizontal do |row|
        if row.radio(@radio == 0, "First").changed?
          @radio = 0
        end
        if row.radio(@radio == 1, "Second").changed?
          @radio = 1
        end
        if row.radio(@radio == 2, "Third").changed?
          @radio = 2
        end
      end
      ui.separator

      ui.label("Slider: #{"%.2f" % @slider}")
      ui.slider(@slider, 0.0..1.0, "value") { |v| @slider = v }

      ui.label("DragValue (drag it):")
      ui.drag_value(@drag, speed: 0.1, suffix: " px") { |v| @drag = v }
      ui.separator

      ui.label("Combo box:")
      ui.combo_box("gallery_combo", @combo, COMBO_OPTIONS) { |opt| @combo = opt }
      ui.separator

      ui.label("Progress (animated):")
      ui.progress_bar(@slider.clamp(0.0, 1.0), animate: true)
      ui.separator

      ui.label("Fancy buttons:")
      ui.horizontal do |row|
        row.add(Egui::Button.new("OK").icon(:check)
          .gradient(Egui::Color32.rgb(60, 150, 90), Egui::Color32.rgb(24, 80, 48)))
        row.add(Egui::Button.new("Cancel").icon(:close))
        row.add(Egui::Button.new("").icon(:plus))
      end
      ui.add(Egui::Button.new("Open modal")
        .gradient(Egui::Color32.rgb(40, 100, 200), Egui::Color32.rgb(16, 42, 92))).clicked?.tap do |clicked|
        @modal_open = true if clicked
      end
      ui.separator

      ui.horizontal do |row|
        row.label("Loading: ")
        row.spinner
        row.hyperlink_to("egui on GitHub", "https://github.com/emilk/egui")
      end

      ui.label("Hover me for a tooltip").on_hover_text("Tooltips work! (0.5s delay)")
    end

    if @modal_open
      ctx.modal("demo") do |ui|
        ui.heading("Modal dialog")
        ui.label("Everything below is blocked while this is open.")
        if ui.button("Close").clicked?
          @modal_open = false
        end
      end
    end

    ctx.bottom_panel("fps") do |ui|
      ui.label("FPS: #{"%.1f" % ctx.fps}")
    end
  end
end

Egui::Backend::Sokol.run(GalleryApp.new, title: "egui-cr — widget gallery",
  width: 900, height: 700)
