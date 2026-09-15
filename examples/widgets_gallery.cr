# egui-cr widget gallery — every widget from phases 1-5, navigated
# through the Sidebar container (sections + tabs): the left side panel
# hosts the sidebar, and the central panel shows the gallery for the
# selected tab (top menu bar and bottom status bar around it).

require "../src/egui"
require "../src/egui/backend/sokol"

class GalleryApp < Egui::App
  # Sidebar navigation: sections of tabs; the central panel dispatches
  # on the selected (section, tab) pair.
  SECTIONS = [
    Egui::Sidebar::Section.new(
      "Widgets", ["Buttons", "Inputs", "Text", "Display", "Color"]),
    Egui::Sidebar::Section.new(
      "Style", ["Themes", "Cursors"]),
    Egui::Sidebar::Section.new(
      "Containers", ["Scroll", "Modal"]),
  ]

  @checked = false
  @radio : Int32 = 1
  @section : Int32 = 0
  @tab : Int32 = 0
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

    # Side panel hosting the Sidebar widget — it draws the sections and
    # tabs and hands back the new selection when a tab is clicked.
    ctx.side_panel(:left, "nav", width: 220.0) do |ui|
      ui.sidebar(SECTIONS, @section, @tab) do |section, tab|
        @section = section
        @tab = tab
      end
    end

    # Central panel: the gallery for the selected tab. The whole content
    # scrolls — everything inside the block goes on the scroll area's
    # inner Ui (putting widgets on the outer one would overlap).
    ctx.central_panel do |ui|
      ui.scroll_area do |scroll|
        scroll.heading(SECTIONS[@section].tabs[@tab])
        scroll.separator

        case {SECTIONS[@section].title, SECTIONS[@section].tabs[@tab]}
        when {"Widgets", "Buttons"}        then buttons_gallery(scroll)
        when {"Widgets", "Inputs"}         then inputs_gallery(scroll)
        when {"Widgets", "Text"}           then text_gallery(scroll)
        when {"Widgets", "Display"}        then display_gallery(scroll)
        when {"Widgets", "Color"}          then color_gallery(scroll)
        when {"Style", "Themes"}           then themes_gallery(scroll, ctx)
        when {"Style", "Cursors"}          then cursors_gallery(scroll)
        when {"Containers", "Scroll"}      then scroll_gallery(scroll)
        when {"Containers", "Modal"}       then modal_gallery(scroll)
        end
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
      ui.label("FPS: #{"%.1f" % ctx.fps} — " \
               "#{SECTIONS[@section].title} / #{SECTIONS[@section].tabs[@tab]}")
    end
  end

  private def buttons_gallery(ui : Egui::Ui) : Nil
    ui.label("Fancy buttons:")
    ui.horizontal do |row|
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
  end

  private def inputs_gallery(ui : Egui::Ui) : Nil
    ui.label("Checkbox / radio:")
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

    ui.label("Slider / drag value:")
    ui.slider(@slider, 0.0..1.0) { |v| @slider = v }
    ui.drag_value(@drag, speed: 0.1, suffix: " px") { |v| @drag = v }
    ui.separator

    ui.label("Combo / text edit:")
    ui.combo_box("gallery_combo", @combo, COMBO_OPTIONS) { |opt| @combo = opt }
    ui.text_edit_singleline(@buffer, hint: "type here…") { |t| @buffer = t }
  end

  private def text_gallery(ui : Egui::Ui) : Nil
    ui.rich(Egui::RichText.new("rich underlined")
      .color(Egui::Color32.rgb(255, 96, 96)).underline)
    ui.hyperlink_to("egui on GitHub", "https://github.com/emilk/egui")
    ui.label("Hover me").on_hover_text("Tooltips work!")
    ui.label("This long paragraph wraps because the label asked for it — resize the window and watch it reflow.", wrap: true)
  end

  private def display_gallery(ui : Egui::Ui) : Nil
    ui.horizontal do |row|
      row.label("Progress:")
      row.progress_bar(@slider.clamp(0.0, 1.0), animate: true)
    end
    ui.label("Spinner:")
    ui.spinner
  end

  private def color_gallery(ui : Egui::Ui) : Nil
    ui.label("Color picker:")
    ui.color_edit32(@color) { |c| @color = c }
  end

  private def themes_gallery(ui : Egui::Ui, ctx : Egui::Context) : Nil
    # Global theme + per-widget override merge. Toggle the theme and
    # watch: everything un-overridden flips palette; the styled
    # widgets keep their custom fields (nil fields follow the theme).
    ui.label("Theme (global + per-widget overrides):")
    ui.horizontal do |row|
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
    ui.add(Egui::Label.new("big red label (font_size + text_color override)")
      .style { |s| s.font_size = 24.0; s.text_color = Egui::Color32.rgb(200, 60, 60) })
    ui.horizontal do |row|
      cb = row.add(Egui::Checkbox.new(@checked, "green text (text_color override)")
        .style { |s| s.text_color = Egui::Color32.rgb(70, 170, 70) })
      @checked = !@checked if cb.changed?
      row.add(Egui::RadioButton.new(@radio == 0, "accent text")
        .style { |s| s.text_color = Egui::Color32.rgb(0, 122, 204) })
    end
    ui.add(Egui::ProgressBar.new(@slider.clamp(0.0, 1.0))
      .style { |s| s.selection_fill = Egui::Color32.rgb(200, 140, 20) })
    ui.add(Egui::Separator.new
      .style { |s| s.separator_color = Egui::Color32.rgb(200, 60, 60) })
    ui.add(Egui::Hyperlink.new("orange link (hyperlink_color override)",
        "https://github.com/emilk/egui")
      .style { |s| s.hyperlink_color = Egui::Color32.rgb(230, 140, 30) })
  end

  private def cursors_gallery(ui : Egui::Ui) : Nil
    # CSS cursor styles: one button per CursorIcon value — hover a
    # button and the mouse takes its cursor (set via the widget
    # style `Button#cursor`).
    Egui::CursorIcon.values.each_slice(6) do |chunk|
      ui.horizontal do |row|
        chunk.each do |icon|
          row.add(Egui::Button.new(icon.to_css).cursor(icon))
        end
      end
    end
  end

  private def scroll_gallery(ui : Egui::Ui) : Nil
    ui.label("Scroll area (wheel me):")
    ui.scroll_area(max_height: 400.0) do |inner|
      25.times { |i| inner.label("scroll row #{i}") }
    end
  end

  private def modal_gallery(ui : Egui::Ui) : Nil
    ui.label("Modal dialog:")
    ui.label("Everything below is blocked while it is open — open it from here or from the Buttons tab.")
    if ui.button("Open modal").clicked?
      @modal_open = true
    end
  end
end

Egui::Backend::Sokol.run(GalleryApp.new, title: "egui-cr — widget gallery",
  width: 900, height: 700)
