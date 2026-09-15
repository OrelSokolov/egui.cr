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
  @color = Egui::Color32.rgb(0, 122, 204)

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
        # Instant global theme swap: assigning ctx.theme restyles the
        # whole UI on the next frame.
        menu.menu_item(ctx.theme.dark? ? "Light theme" : "Dark theme") do
          ctx.theme = ctx.theme.dark? ? Egui::Theme.light : Egui::Theme.dark
        end
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
    # The whole content scrolls — the list is taller than the panel,
    # so the color picker at the end is reached by wheel. Everything
    # inside the block goes on the scroll area's inner Ui (putting
    # widgets on the outer one would overlap: its cursor only moves
    # past the scroll area after the block returns).
    ctx.central_panel do |ui|
      ui.scroll_area do |scroll|
        scroll.horizontal do |row|
          row.label("Progress:")
          row.progress_bar(@slider.clamp(0.0, 1.0), animate: true)
        end

        scroll.separator
        scroll.label("Fancy buttons:")
        scroll.horizontal do |row|
          row.add(Egui::Button.new("OK").icon(:check)
            .gradient(Egui::Color32.rgb(60, 150, 90), Egui::Color32.rgb(24, 80, 48)))
          row.add(Egui::Button.new("Cancel").icon(:close))
          row.add(Egui::Button.new("Open modal")
            .gradient(Egui::Color32.rgb(40, 100, 200), Egui::Color32.rgb(16, 42, 92))).clicked?.tap do |c|
            @modal_open = true if c
          end
          # Per-widget style: merged over the app theme (nil fields keep
          # the theme value), so the fill stays custom across theme
          # swaps while the stroke/text follow the theme.
          row.add(Egui::Button.new("Themed red").style do |s|
            s.fill = Egui::Color32.rgb(170, 40, 40)
            s.fill_hovered = Egui::Color32.rgb(200, 55, 55)
            s.fill_active = Egui::Color32.rgb(140, 25, 25)
          end)
        end
        scroll.separator

        # Global theme + per-widget override merge. Toggle the theme and
        # watch: everything un-overridden flips palette; the styled
        # widgets keep their custom fields (nil fields follow the theme).
        scroll.label("Theme (global + per-widget overrides):")
        scroll.horizontal do |row|
          if row.button("Dark theme").clicked?
            ctx.theme = Egui::Theme.dark
          end
          if row.button("Light theme").clicked?
            ctx.theme = Egui::Theme.light
          end
          row.label("active: #{ctx.theme}")
        end
        # Override demos — one styled field each, everything else
        # inherited from the active theme.
        scroll.add(Egui::Label.new("big red label (font_size + text_color override)")
          .style { |s| s.font_size = 24.0; s.text_color = Egui::Color32.rgb(200, 60, 60) })
        scroll.horizontal do |row|
          cb = row.add(Egui::Checkbox.new(@checked, "green text (text_color override)")
            .style { |s| s.text_color = Egui::Color32.rgb(70, 170, 70) })
          @checked = !@checked if cb.changed?
          row.add(Egui::RadioButton.new(@radio == 0, "accent text")
            .style { |s| s.text_color = Egui::Color32.rgb(0, 122, 204) })
        end
        scroll.add(Egui::ProgressBar.new(@slider.clamp(0.0, 1.0))
          .style { |s| s.selection_fill = Egui::Color32.rgb(200, 140, 20) })
        scroll.add(Egui::Separator.new
          .style { |s| s.separator_color = Egui::Color32.rgb(200, 60, 60) })
        scroll.add(Egui::Hyperlink.new("orange link (hyperlink_color override)",
            "https://github.com/emilk/egui")
          .style { |s| s.hyperlink_color = Egui::Color32.rgb(230, 140, 30) })
        scroll.separator

        # CSS cursor styles: one button per CursorIcon value — hover a
        # button and the mouse takes its cursor (set via the widget
        # style `Button#cursor`).
        scroll.label("Cursors (CSS cursor styles):")
        Egui::CursorIcon.values.each_slice(6) do |chunk|
          scroll.horizontal do |row|
            chunk.each do |icon|
              row.add(Egui::Button.new(icon.to_css).cursor(icon))
            end
          end
        end
        scroll.separator

        scroll.label("Scroll area (wheel me):")
        scroll.scroll_area(max_height: 160.0) do |inner|
          25.times { |i| inner.label("scroll row #{i}") }
        end
        scroll.separator

        scroll.rich(Egui::RichText.new("rich underlined").color(Egui::Color32.rgb(255, 96, 96)).underline)
        scroll.hyperlink_to("egui on GitHub", "https://github.com/emilk/egui")
        scroll.label("Hover me").on_hover_text("Tooltips work!")
        scroll.label("This long paragraph wraps because the label asked for it — resize the window and watch it reflow.", wrap: true)

        scroll.separator
        scroll.label("Color picker:")
        scroll.color_edit32(@color) { |c| @color = c }
      end
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
