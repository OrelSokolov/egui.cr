# egui-cr widget gallery — every widget from phases 1-5, navigated
# through the Sidebar container (sections + tabs): the left side panel
# hosts the sidebar, and the central panel shows the gallery for the
# selected tab (top menu bar and bottom status bar around it).

require "../src/egui"
require "../src/egui/backend/sokol"

class GalleryApp < Egui::App
  @checked = false
  @radio : Int32 = 1
  @section : Int32 = 0
  @tab : Int32 = 0
  @slider = 0.3_f64
  @drag = 10.0_f64
  @combo = "Second"
  @modal_open = false
  @buffer = "edit me"
  @notes = "first line\nsecond line"
  @color = Egui::Color32.rgb(0, 122, 204)
  @seg = 0
  @sel = false
  @tree_sel = ""
  @opened : String? = nil
  @date = Time.local(2026, 9, 15)
  @enabled = true
  @wizard_done = false
  # InfoBar demo (Rails-style flash): the message + its level; the
  # infobar itself dismisses (X or the auto-hide timer).
  @flash : {String, Symbol}? = nil
  # TabBar demo: closable tabs over inline content.
  @tab_labels = ["Overview", "Details", "History", "Raw"]
  @tab_sel = 0
  # Standalone vscrollbar demo: the app owns the offset.
  @scroll_off = 0.0
  # Procedural texture for the Image demo (registered on first frame).
  @demo_texture : UInt64 = 0_u64
  # App stylesheet rules are registered once, on the first frame.
  @styled = false

  # Sidebar navigation: sections of tabs, all closable — the X nested
  # in each tab removes it (and the whole section when it empties).
  # Mutable app state (not a constant) because tabs disappear.
  @sections = [
    Egui::Sidebar::Section.new(
      "Widgets", ["Buttons", "Inputs", "Text", "Display", "Color", "Image"],
      closable: true),
    Egui::Sidebar::Section.new(
      "Style", ["Themes", "Cursors"], closable: true),
    Egui::Sidebar::Section.new(
      "Containers", ["Scroll", "Tabs", "Modal", "Dialogs", "Window Modals"], closable: true),
    Egui::Sidebar::Section.new(
      "Layout", ["Grid", "Table", "Tree", "Plot", "Enabled"], closable: true),
  ]

  COMBO_OPTIONS = ["First", "Second", "Third"]

  def update(ctx : Egui::Context) : Nil
    setup_styles(ctx) unless @styled

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
        # Introspection: the whole style tree (classes → states → keys)
        # goes to stdout — `ctx.stylesheet.dump` accepts any IO.
        menu.menu_item("Dump stylesheet (stdout)") { puts ctx.stylesheet }
        # Instant global theme swap: assigning ctx.theme restyles the
        # whole UI on the next frame.
        menu.menu_item(ctx.theme.dark? ? "Light theme" : "Dark theme") do
          ctx.theme = ctx.theme.dark? ? Egui::Theme.light : Egui::Theme.dark
        end
      end
      # Classic GTK placement: About lives under Help.
      bar.menu_button("Help") do |menu|
        menu.menu_item("About egui.cr Gallery…") do
          Egui::AboutModal.new("gallery_about", "egui.cr Gallery").open(ctx)
        end
        menu.menu_item("Setup wizard…") do
          Egui::WizardModal.new("gallery_wizard", "Gallery setup wizard", 3) { }.open(ctx)
        end
      end
    end

    # Side panel hosting the Sidebar widget — it draws the sections and
    # tabs, hands back the new selection when a tab is clicked, and
    # reports closes from the nested X buttons.
    ctx.side_panel(:left, "nav", width: 220.0) do |ui|
      ui.sidebar(@sections, @section, @tab,
        on_close: ->(si : Int32, ti : Int32) { close_tab(si, ti) }) do |section, tab|
        @section = section
        @tab = tab
      end
    end

    # Central panel: the gallery for the selected tab. The whole content
    # scrolls — everything inside the block goes on the scroll area's
    # inner Ui (putting widgets on the outer one would overlap).
    ctx.central_panel do |ui|
      if @sections.empty?
        ui.label("Every tab is closed — nowhere to navigate. (Restart the app to get them back.)")
      else
        ui.scroll_area do |scroll|
          scroll.heading(@sections[@section].tabs[@tab])
          scroll.separator

          case {@sections[@section].title, @sections[@section].tabs[@tab]}
          when {"Widgets", "Buttons"}        then buttons_gallery(scroll)
          when {"Widgets", "Inputs"}         then inputs_gallery(scroll)
          when {"Widgets", "Text"}           then text_gallery(scroll)
          when {"Widgets", "Display"}        then display_gallery(scroll)
          when {"Widgets", "Color"}          then color_gallery(scroll)
          when {"Widgets", "Image"}          then image_gallery(scroll, ctx)
          when {"Style", "Themes"}           then themes_gallery(scroll, ctx)
          when {"Style", "Cursors"}          then cursors_gallery(scroll)
          when {"Containers", "Scroll"}      then scroll_gallery(scroll)
          when {"Containers", "Tabs"}        then tabs_gallery(scroll)
          when {"Containers", "Modal"}       then modal_gallery(scroll)
          when {"Containers", "Dialogs"}     then dialogs_gallery(scroll)
          when {"Containers", "Window Modals"} then window_modals_gallery(scroll)
          when {"Layout", "Grid"}            then grid_gallery(scroll)
          when {"Layout", "Table"}           then table_gallery(scroll)
          when {"Layout", "Tree"}            then tree_gallery(scroll)
          when {"Layout", "Plot"}            then plot_gallery(scroll)
          when {"Layout", "Enabled"}         then enabled_gallery(scroll)
          end
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

    # GTK-style window modals (WindowModal): open state lives in
    # Memory — construct and #show every frame; they render nothing
    # while closed. Opened from the Window Modals tab, the Help menu
    # (About/wizard) and the Color tab (chooser).
    Egui::ColorChooserModal.new("gallery_color", @color) { |c| @color = c }.show(ctx)

    about = Egui::AboutModal.new("gallery_about", "egui.cr Gallery")
    about.version = "0.36.2-cr"
    about.comments = "Immediate-mode GUI for Crystal — a 1:1 architectural " \
                     "port of egui (Rust) onto sokol."
    about.website_url = "https://github.com/emilk/egui"
    about.website_label = "upstream egui"
    about.authors = ["Oleg"]
    about.copyright = "(c) 2026 egui.cr contributors"
    about.show(ctx)

    Egui::WizardModal.new("gallery_wizard", "Gallery setup wizard", 3) do
      @wizard_done = true
    end.show(ctx) { |ui, page| wizard_page(ui, page) }

    ctx.bottom_panel("fps") do |ui|
      if @sections.empty?
        ui.label("FPS: #{"%.1f" % ctx.fps}")
      else
        ui.label("FPS: #{"%.1f" % ctx.fps} — " \
                 "#{@sections[@section].title} / #{@sections[@section].tabs[@tab]}")
      end
    end
  end

  # A tab's X was clicked: drop the tab (the whole section when it
  # empties) and fix the selection indices around the removal.
  private def close_tab(si : Int32, ti : Int32) : Nil
    section = @sections[si]
    tabs = section.tabs.dup
    tabs.delete_at(ti)

    if tabs.empty?
      @sections.delete_at(si)
      @section -= 1 if si < @section
    else
      @sections[si] = Egui::Sidebar::Section.new(section.title, tabs,
        closable: true)
    end

    return if @sections.empty?

    @section = @section.clamp(0, @sections.size - 1)
    @tab -= 1 if si == @section && ti < @tab
    @tab = @tab.clamp(0, @sections[@section].tabs.size - 1)
  end

  # The button variants as CSS class rules — Bootstrap-2 flavored:
  # gradients for success/primary (hover/active shading is computed by
  # the widget), plain state fills for danger. No per-widget colors.
  private def setup_styles(ctx : Egui::Context) : Nil
    @styled = true
    sheet = ctx.stylesheet
    sheet.rule("button.success", Egui::StyleVars{
      "background_gradient" => Egui::Gradient.new(
        Egui::Color32.rgb(60, 150, 90), Egui::Color32.rgb(24, 80, 48)),
      "border_color" => Egui::Color32.rgb(18, 58, 34),
    })
    sheet.rule("button.primary", Egui::StyleVars{
      "background_gradient" => Egui::Gradient.new(
        Egui::Color32.rgb(40, 100, 200), Egui::Color32.rgb(16, 42, 92)),
      "border_color" => Egui::Color32.rgb(12, 32, 70),
    })
    sheet.rule("button.danger", Egui::StyleVars{
      "fill"         => Egui::Color32.rgb(170, 40, 40),
      "border_color" => Egui::Color32.rgb(96, 16, 16),
    })
    sheet.rule("button.danger:hover",
      Egui::StyleVars{"fill" => Egui::Color32.rgb(200, 55, 55)})
    sheet.rule("button.danger:active",
      Egui::StyleVars{"fill" => Egui::Color32.rgb(140, 25, 25)})
  end

  private def buttons_gallery(ui : Egui::Ui) : Nil
    ui.label("Fancy buttons:")
    ui.horizontal do |row|
      # Everything below comes from the stylesheet rules above —
      # gradient, border color and state fills all live in CSS.
      row.add(Egui::Button.new("OK").icon(:check).css("success"))
      row.add(Egui::Button.new("Cancel").icon(:close))
      row.add(Egui::Button.new("Open modal").css("primary")).clicked?.tap do |c|
        @modal_open = true if c
      end
      row.add(Egui::Button.new("Themed red").css("danger"))
    end
    # Right-click anything below — a context menu opens at the pointer
    # (egui `Response#context_menu`; `menu_item` rows close it, a click
    # elsewhere dismisses it).
    ui.label("Context menu (right-click me):").context_menu do |menu|
      menu.menu_item("Copy") { }
      menu.menu_item("Paste") { }
      menu.menu_item("Delete") { }
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
    ui.label("Multiline text edit (Enter breaks lines, view scrolls):")
    ui.text_edit_multiline(@notes, rows: 5) { |t| @notes = t }
    ui.separator

    ui.label("Toggle / segmented / selectable:")
    ui.toggle_button(@checked, "Switch (#{@checked})") { |v| @checked = v }
    ui.horizontal do |row|
      row.label("Segment:")
      row.segmented(@seg, ["One", "Two", "Three"]) { |i| @seg = i }
    end
    ui.horizontal do |row|
      row.label("Selectable:")
      row.selectable(@sel, "selectable label (#{@sel})") { |v| @sel = v }
    end
    ui.separator

    ui.label("Date picker:")
    ui.date_picker("gallery_date", @date) { |t| @date = t }
    ui.drag_value(@drag, speed: 0.1, suffix: " px",
      format: ->(v : Float64) { "%.1f" % v }) { |v| @drag = v }
  end

  private def text_gallery(ui : Egui::Ui) : Nil
    ui.rich(Egui::RichText.new("rich underlined")
      .color(Egui::Color32.rgb(255, 96, 96)).underline)
    ui.hyperlink_to("egui on GitHub", "https://github.com/emilk/egui")
    ui.label("Hover me").on_hover_text("Tooltips work!")
    ui.label("This long paragraph wraps because the label asked for it — resize the window and watch it reflow.", wrap: true)
    ui.separator
    # Block text alignment (CSS text-align): the label takes the full
    # row width and paints left/center/right — also settable as a
    # per-widget style (`s.text_align = :center`) or RichText#align.
    ui.label("Alignment (text: left / center / right):")
    ui.label("left-aligned", align: :left)
    ui.label("centered", align: :center)
    ui.label("right-aligned", align: :right)
    ui.hyperlink_to("centered link", "https://github.com/emilk/egui", align: :center)
  end

  private def display_gallery(ui : Egui::Ui) : Nil
    ui.label("Progress:")
    ui.horizontal do |row|
      row.progress_bar(@slider.clamp(0.0, 1.0), animate: true)
    end
    ui.label("Spinner:")
    ui.spinner
    ui.separator

    infobar_gallery(ui)
    ui.separator
    vscrollbar_gallery(ui)
  end

  # InfoBar (Rails-style flash): buttons raise flashes of each level;
  # the bar dismisses itself via its X or the auto-hide timer and the
  # app drops the message in the block.
  private def infobar_gallery(ui : Egui::Ui) : Nil
    ui.label("InfoBar (flash messages, auto-hide after 4s):")
    ui.horizontal do |row|
      {"info" => :info, "success" => :success,
       "warning" => :warning, "error" => :error}.each do |name, level|
        if row.button(name).clicked?
          @flash = {"This is a #{name} flash message.", level}
        end
      end
    end
    if (flash = @flash)
      ui.infobar(flash[0], level: flash[1], auto_hide: 4.0) do
        @flash = nil
      end
    end
  end

  # Standalone vscrollbar: the offset lives in app state, not in a
  # ScrollArea — the list pane is a manually clipped child Ui (the
  # ScrollArea trick, done by hand to show what the bar is for).
  private def vscrollbar_gallery(ui : Egui::Ui) : Nil
    ui.label("Standalone vscrollbar (app-owned offset):")
    list_h = 150.0
    rows = 40
    row_h = ui.style.font_size * Egui::Fonts::LINE_H_FACTOR +
            ui.style.spacing.item_spacing.y
    content_h = rows * row_h
    viewport = Egui::Rect.from_min_size(ui.cursor,
      Egui::Vec2.new(ui.available_width, list_h))

    clip_save = ui.painter.clip
    pane = Egui::Rect.from_min_size(viewport.min,
      Egui::Vec2.new(viewport.width - 20.0, list_h))
    ui.painter.clip = Egui::Rect.new(
      Egui::Pos2.new({clip_save.min.x, pane.min.x}.max,
        {clip_save.min.y, pane.min.y}.max),
      Egui::Pos2.new({clip_save.max.x, pane.max.x}.min,
        {clip_save.max.y, pane.max.y}.min))
    inner = ui.child_ui(Egui::Rect.from_min_size(
      pane.min + Egui::Vec2.new(0.0, -@scroll_off),
      Egui::Vec2.new(pane.width, 1e6)))
    inner.painter.rect(pane, 4.0, ui.style.visuals.button_weak)
    rows.times { |i| inner.label("custom list row #{i}") }
    ui.painter.clip = clip_save

    ui.cursor = Egui::Pos2.new(pane.right + 8.0, viewport.top)
    ui.vscrollbar(@scroll_off, content_h, list_h, height: list_h) do |off|
      @scroll_off = off
    end

    ui.min_rect = ui.min_rect.union(viewport)
    ui.cursor = Egui::Pos2.new(ui.max_rect.min.x,
      viewport.bottom + ui.style.spacing.item_spacing.y)
    ui.label("(drag the thumb or press the track)")
  end

  # Image widget: a procedural texture (registered once through the
  # TextureRegistry) shown at several sizes, plus the failed-load
  # placeholder a texture id of 0 renders as.
  private def image_gallery(ui : Egui::Ui, ctx : Egui::Context) : Nil
    if @demo_texture.zero?
      w = h = 64
      pixels = Slice(UInt8).new(w * h * 4)
      h.times do |y|
        w.times do |x|
          i = (y * w + x) * 4
          pixels[i] = (x * 255 // (w - 1)).to_u8
          pixels[i + 1] = (y * 255 // (h - 1)).to_u8
          pixels[i + 2] = 180_u8
          pixels[i + 3] = 255_u8
        end
      end
      @demo_texture = ctx.textures.register_rgba(w, h, pixels)
    end

    ui.label("ui.image (procedural gradient texture, tinted variants):")
    ui.horizontal do |row|
      row.image(@demo_texture, Egui::Vec2.new(96.0, 96.0))
      row.image(@demo_texture, Egui::Vec2.new(48.0, 48.0),
        tint: Egui::Color32.rgb(255, 160, 160))
      row.image(@demo_texture, Egui::Vec2.new(24.0, 24.0),
        tint: Egui::Color32.rgb(160, 255, 160))
    end
    ui.label("Failed load (texture id 0 → placeholder):")
    ui.image(0_u64, Egui::Vec2.new(96.0, 64.0))
    ui.label("Files load through ctx.load_image(path) (PNG/JPEG via stb_image); " \
             "the id flows straight into ui.image.", wrap: true)
  end

  # Horizontal tabs (TabBar): the selection lives in app state, the
  # block hands the new index back; closable tabs show the nested X.
  private def tabs_gallery(ui : Egui::Ui) : Nil
    ui.label("Tabs (horizontal TabBar, closable):")
    ui.tabs(@tab_labels, @tab_sel, closable: true,
      on_close: ->(i : Int32) { close_gallery_tab(i) }) { |i| @tab_sel = i }

    if @tab_labels.empty?
      ui.label("Every tab closed — reopen them from the button below.")
      if ui.button("Reset tabs").clicked?
        @tab_labels = ["Overview", "Details", "History", "Raw"]
        @tab_sel = 0
      end
      return
    end

    ui.separator
    case @tab_labels[@tab_sel]
    when "Overview" then ui.label("Overview: a summary of everything.", wrap: true)
    when "Details"  then ui.label("Details: the fine print nobody reads.", wrap: true)
    when "History"  then ui.label("History: created, edited, closed.", wrap: true)
    else                 ui.label("Raw: 0x00 0x01 0x02 0x03 …", wrap: true)
    end
  end

  # A gallery tab's X: drop it and fix the selection around it.
  private def close_gallery_tab(i : Int32) : Nil
    @tab_labels.delete_at(i)
    @tab_sel -= 1 if i < @tab_sel
    @tab_sel = @tab_sel.clamp(0, {@tab_labels.size - 1, 0}.max)
  end

  private def color_gallery(ui : Egui::Ui) : Nil
    ui.label("Color picker (inline):")
    ui.color_edit32(@color) { |c| @color = c }
    ui.separator
    ui.label("Color chooser dialog (GTK-style WindowModal):")
    ui.horizontal do |row|
      if row.button("Choose color…").clicked?
        Egui::ColorChooserModal.new("gallery_color", @color) { |c| @color = c }.open(ui.ctx)
      end
      rect = row.allocate_space(Egui::Vec2.new(28.0, 18.0))
      row.painter.rect(rect, 3.0, @color, row.style.visuals.border_color, 1.0)
      row.label(Egui::ColorChooserModal.hex(@color))
    end
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

    ui.separator
    sidebar_style_gallery(ui, ctx)
  end

  private def sidebar_style_gallery(ui : Egui::Ui, ctx : Egui::Context) : Nil
    # Live CSS-like restyle: `rule` merges into the class bag and the
    # sidebar re-reads it next frame (the merged bags are cached, a
    # rule drops the cache — nothing is rebuilt per frame). All the
    # defaults these tweaks build on live in src/egui/default_theme.cr.
    ui.label("Sidebar stylesheet (live restyle, defaults in default_theme.cr):")
    sheet = ctx.stylesheet
    pad = sheet.resolve(Egui::Sidebar::TAB_CLASS).box("padding")
    margin = sheet.resolve(Egui::Sidebar::SECTION_CLASS).box("margin")
    ui.horizontal do |row|
      if row.button("− padding").clicked?
        sheet.rule(Egui::Sidebar::TAB_CLASS, Egui::StyleVars{
          "padding.top"    => (pad.top - 1).clamp(0.0, 24.0),
          "padding.bottom" => (pad.bottom - 1).clamp(0.0, 24.0),
        })
      end
      if row.button("+ padding").clicked?
        sheet.rule(Egui::Sidebar::TAB_CLASS, Egui::StyleVars{
          "padding.top"    => (pad.top + 1).clamp(0.0, 24.0),
          "padding.bottom" => (pad.bottom + 1).clamp(0.0, 24.0),
        })
      end
      if row.button("− margin").clicked?
        sheet.rule(Egui::Sidebar::SECTION_CLASS,
          Egui::StyleVars{"margin.top" => (margin.top - 2).clamp(0.0, 40.0)})
      end
      if row.button("+ margin").clicked?
        sheet.rule(Egui::Sidebar::SECTION_CLASS,
          Egui::StyleVars{"margin.top" => (margin.top + 2).clamp(0.0, 40.0)})
      end
    end
    ui.label("tab padding.top #{"%.1f" % pad.top}, section margin.top #{"%.1f" % margin.top}")
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

  # GTK-style window modals: each is a WindowModal — an imitation of
  # an OS window inside the app (title bar with drag + close, content
  # area, right-aligned button row), riding the modal layer.
  private def window_modals_gallery(ui : Egui::Ui) : Nil
    ui.label("GTK-style dialogs as window-like modals (WindowModal):")
    ui.label("title bar (drag to move, X to close), content area, button row; Escape closes.")
    ui.horizontal do |row|
      row.label("Chosen color:")
      rect = row.allocate_space(Egui::Vec2.new(28.0, 18.0))
      row.painter.rect(rect, 3.0, @color, row.style.visuals.border_color, 1.0)
      row.label(Egui::ColorChooserModal.hex(@color))
    end
    if ui.button("Color chooser…").clicked?
      Egui::ColorChooserModal.new("gallery_color", @color) { |c| @color = c }.open(ui.ctx)
    end
    if ui.button("About…").clicked?
      Egui::AboutModal.new("gallery_about", "egui.cr Gallery").open(ui.ctx)
    end
    if ui.button("Setup wizard…").clicked?
      Egui::WizardModal.new("gallery_wizard", "Gallery setup wizard", 3) { }.open(ui.ctx)
    end
    ui.separator
    ui.label(@wizard_done ? "Wizard: finished" : "Wizard: not finished yet")
    ui.label("(also reachable from the Help menu; the chooser from the Color tab)")
  end

  private def wizard_page(ui : Egui::Ui, page : Int32) : Nil
    case page
    when 0
      ui.heading("Welcome", align: :center)
      ui.label("This wizard walks you through the gallery setup.", wrap: true, align: :center)
    when 1
      ui.heading("Preferences", align: :center)
      ui.checkbox(@checked, "Enable fancy extras") { |v| @checked = v }
      ui.slider(@slider, 0.0..1.0) { |v| @slider = v }
    when 2
      ui.heading("Ready", align: :center)
      ui.label("Press Finish to complete the setup.", wrap: true, align: :center)
    end
  end

  # System ports demo (from the hello example): the native file picker
  # runs in its own fiber (AsyncDialogs) and never blocks the frame —
  # the path arrives in the callback on a later frame, meanwhile the
  # UI keeps rendering ("opening…" row).
  private def dialogs_gallery(ui : Egui::Ui) : Nil
    ui.label("Native open-file dialog (fiber-backed, non-blocking):")
    if ui.button("Open file…").clicked?
      @opened = nil
      Egui::SystemPorts::OpenFileDialog.show(
        filters: ["*.png", "*.jpg"]) { |path| @opened = path }
    end
    if Egui::SystemPorts::AsyncDialogs.pending?
      ui.spinner
      ui.label("opening…")
    else
      ui.label("opened: #{@opened || "—"}")
    end
  end

  # Aligned columns: column widths are measured frame N and applied
  # frame N+1 (persisted per grid in Memory), like upstream egui Grid.
  private def grid_gallery(ui : Egui::Ui) : Nil
    ui.label("Grid (aligned columns):")
    ui.grid("gallery_grid") do |grid|
      grid.label("Setting"); grid.label("Value"); grid.label("Note"); grid.end_row
      grid.label("width"); grid.label("1920"); grid.label("pixels, screen"); grid.end_row
      grid.label("height"); grid.label("1080"); grid.label("a much longer note that sets the column width"); grid.end_row
      grid.label("scale"); grid.label("100%"); grid.label("—"); grid.end_row
    end
  end

  private def table_gallery(ui : Egui::Ui) : Nil
    ui.label("Table (header + aligned rows, on Grid):")
    ui.table("gallery_table", ["File", "Size", "Modified"],
      [0.5, 0.2, 0.3]) do |rows|
      rows.label("README.md"); rows.label("4 KB"); rows.label("today"); rows.end_row
      rows.label("shard.yml"); rows.label("1 KB"); rows.label("yesterday"); rows.end_row
      rows.label("src/"); rows.label("—"); rows.label("2 days ago"); rows.end_row
      rows.label("lib/libegui_cr_sokol.a"); rows.label("2.1 MB"); rows.label("last build"); rows.end_row
    end
  end

  # Tree state (which branches are open) lives in Memory keyed by node
  # path — the app only tracks the selected leaf.
  private def tree_gallery(ui : Egui::Ui) : Nil
    ui.label("Tree view (open/close state is app-independent):")
    ui.label("selected: #{@tree_sel.empty? ? "(none)" : @tree_sel}")
    ui.tree_view("gallery_tree") do |tree|
      tree.node("src", default_open: true) do |sub|
        sub.leaf("egui.cr", @tree_sel == "src/egui.cr") { @tree_sel = "src/egui.cr" }
        sub.node("widgets", default_open: true) do |leaf|
          leaf.leaf("button.cr", @tree_sel == "src/widgets/button.cr") { @tree_sel = "src/widgets/button.cr" }
          leaf.leaf("slider.cr", @tree_sel == "src/widgets/slider.cr") { @tree_sel = "src/widgets/slider.cr" }
        end
      end
      tree.leaf("README.md", @tree_sel == "README.md") { @tree_sel = "README.md" }
    end
  end

  # Line + scatter over shared axes; drag to pan, wheel to zoom (around
  # the pointer). Bounds auto-fit until the first interaction, then
  # persist in Memory keyed by the plot id.
  private def plot_gallery(ui : Egui::Ui) : Nil
    ui.label("Plot (drag to pan, wheel to zoom):")
    sin = (0..100).map { |i|
      x = i * 0.1
      {x, Math.sin(x)}
    }
    peaks = sin.select { |_, y| y > 0.95 }
    ui.plot("gallery_plot", height: 220) do |p|
      p.line("sin(x)", sin)
      p.points("peaks", peaks)
    end
  end

  # egui `ui.enabled(flag)`: the region renders, but every Response is
  # dead and a scrim is painted over it. Toggling re-enables the same
  # widgets with their state intact (open flag, checkbox, focus).
  private def enabled_gallery(ui : Egui::Ui) : Nil
    ui.label("ui.enabled(flag) — grayed regions keep their state:")
    ui.toggle_button(@enabled, "Enable the block below") { |v| @enabled = v }
    ui.separator
    ui.enabled(@enabled) do |block|
      block.label("The widgets inside are dead while disabled:")
      block.checkbox(@checked, "checkbox (state kept)") { |v| @checked = v }
      Egui::CollapsingHeader.new("header kept open/closed too")
        .show(block) { |inner| inner.label("nested content") }
      block.button("Can't click me")
    end
    ui.label("Columns (ui.columns n):")
    ui.columns(3) do |cols|
      cols.each_with_index do |col, i|
        col.label("column #{i}")
        col.label("second line")
      end
    end
  end
end

Egui::Backend::Sokol.run(GalleryApp.new, title: "egui-cr — widget gallery",
  width: 900, height: 700)
