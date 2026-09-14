# egui-cr widget gallery — every widget from phases 1-5, laid out on
# the panel system (top menu bar, left side panel, central panel,
# bottom status bar), with a scrollable widget list.

require "../src/egui"
require "../src/egui/backend/sokol"

class GalleryApp < Egui::App
  @checked = false
  @radio : Int32 = 1
  @slider = 0.3_f64
  @drag = 10.0_f64
  @combo = "Second"
  @modal_open = false
  @buffer = "edit me"

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

    # Side panel with the simple widget list.
    ctx.side_panel(:left, "widgets", width: 260.0) do |ui|
      ui.heading("Simple widgets")
      ui.checkbox(@checked, "Checkbox (#{@checked})") { |v| @checked = v }

      ui.horizontal do |row|
        if row.radio(@radio == 0, "First").changed?
          @radio = 0
        end
        if row.radio(@radio == 1, "Second").changed?
          @radio = 1
        end
      end
      ui.separator

      ui.label("Slider")
      ui.slider(@slider, 0.0..1.0) { |v| @slider = v }
      ui.drag_value(@drag, speed: 0.1, suffix: " px") { |v| @drag = v }
      ui.separator

      ui.label("Combo")
      ui.combo_box("gallery_combo", @combo, COMBO_OPTIONS) { |opt| @combo = opt }
      ui.text_edit_singleline(@buffer, hint: "type here…") { |t| @buffer = t }
    end

    # Central panel: scrollable content + the rest of the widgets.
    ctx.central_panel do |ui|
      ui.horizontal do |row|
        row.label("Progress:")
        row.progress_bar(@slider.clamp(0.0, 1.0), animate: true)
      end

      ui.separator
      ui.label("Fancy buttons:")
      ui.horizontal do |row|
        row.add(Egui::Button.new("OK").icon(:check)
          .gradient(Egui::Color32.rgb(60, 150, 90), Egui::Color32.rgb(24, 80, 48)))
        row.add(Egui::Button.new("Cancel").icon(:close))
        row.add(Egui::Button.new("Open modal")
          .gradient(Egui::Color32.rgb(40, 100, 200), Egui::Color32.rgb(16, 42, 92))).clicked?.tap do |c|
          @modal_open = true if c
        end
      end
      ui.separator

      ui.label("Scroll area (wheel me):")
      ui.scroll_area(max_height: 160.0) do |scroll|
        25.times { |i| scroll.label("scroll row #{i}") }
      end
      ui.separator

      ui.rich(Egui::RichText.new("rich underlined").color(Egui::Color32.rgb(255, 96, 96)).underline)
      ui.hyperlink_to("egui on GitHub", "https://github.com/emilk/egui")
      ui.label("Hover me").on_hover_text("Tooltips work!")
      ui.label("This long paragraph wraps because the label asked for it — resize the window and watch it reflow.", wrap: true)
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
