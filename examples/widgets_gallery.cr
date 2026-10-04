# egui-cr widget gallery — every widget from phases 1-5, navigated
# through the Sidebar container (sections + tabs): the left side panel
# hosts the sidebar, and the central panel shows the gallery for the
# selected tab (top menu bar and bottom status bar around it).

require "../src/egui"
require "../src/egui/backend/sokol"
require "./icon"
require "./logo_variants"

class GalleryApp < Egui::App
  # Static plot data as computeds: built once on first read, not on
  # every frame (they were rebuilt 60×/s while the Plot tab is open).
  # The animated CPU curve below is deliberately NOT a computed — its
  # x window slides every frame, so memoization has nothing to save;
  # its memoizable part (the per-second random walk) is already cached
  # in @cpu_samples.
  computed sin_points : Array({Float64, Float64}) = (0..100).map { |i|
    x = i * 0.1
    {x, Math.sin(x)}
  }

  # computed-of-computed: peaks derive from sin_points.
  computed peak_points : Array({Float64, Float64}) = begin
    sin_points.select { |_, y| y > 0.95 }
  end

  @checked = false
  @radio : Int32 = 1
  @section : Int32 = 0
  @tab : Int32 = 0
  @slider = 0.3_f64
  # Slider tab: one state var per variation (see #slider_gallery).
  @slider_nt = 0.7_f64
  @slider_tips = 65.0_f64
  @slider_q = 0.5_f64
  @slider_qt = 0.5_f64
  @slider_tick = 0.25_f64
  @drag = 10.0_f64
  @spin = 42
  @combo = "Second"
  @combo_none = ""
  @font_family = "system"
  @font_size = 16.0
  @modal_open = false
  @buffer = "edit me"
  # Long enough to overflow the field — demonstrates the max-width
  # rule: the edit stays region-width and scrolls inside instead of
  # growing past the panel.
  @buffer2 = "Second edit " + "1" * 80
  # Password field demo state — masked input in the Inputs tab.
  @password = "hunter2"
  # Textarea demo tab: the multiline buffer — long enough to overflow
  # the 14-row box so the kinetic scroll has something to scroll.
  @ta_text : String = (1..40).map { |i|
    "line #{i} — the quick brown fox jumps over the lazy dog"
  }.join('\n')
  @color = Egui::Color32.rgb(0, 122, 204)
  @seg = 0
  @sel = false
  @tree_sel = ""
  @date = Time.local(2026, 9, 15)
  @enabled = true
  # Dropped files (drag & drop) and the update-call counter that shows
  # on-demand repaint at work: it only ticks when the UI really runs.
  @dropped = [] of String
  @updates = 0
  # Animated plot: emulated CPU load. A fresh value every whole second
  # (random walk + spikes, 0..100%), smoothly interpolated in between —
  # the view is a sliding window over the last 60 seconds, so the curve
  # flows left → right every frame. Lazy map: second index → load %.
  @cpu_samples = Hash(Int32, Float64).new
  # Monotonic counter for tabs created via File → New ("tab 1", "tab 2"…).
  @next_tab = 1
  # Hotkeys: defaults bound once on the first frame; @last_action is
  # the most recent action event (menu click or hotkey press).
  @hotkeys_ready = false
  @last_action = "(none)"
  # Logos tab: render size of the Egui::Svg previews.
  @logo_size = 72.0_f64
  # Context menu tab: reusable menu definitions, built lazily (see
  # #text_menu / #input_menu / #button_menu).
  @text_menu : Egui::ContextMenu?
  @input_menu : Egui::ContextMenu?
  @button_menu : Egui::ContextMenu?
  # System-style presets (Ubuntu / Windows XP / Windows 11 / macOS),
  # built lazily once — themes are swapped by reference, so the Theme
  # instances are reused across clicks (see #system_themes).
  @system_themes : Array(Egui::Theme)?

  # `--styled` — boot straight into a custom stylesheet theme (the
  # screenshot demo of the CSS cascade: one derived theme restyles
  # every widget at once). Applied once, on the first frame.
  @styled : Bool = ARGV.includes?("--styled")
  @styled_applied = false

  # Sidebar navigation: sections of tabs, all closable — the X nested
  # in each tab removes it (and the whole section when it empties).
  # Mutable app state (not a constant) because tabs disappear.
  @sections = [
    Egui::Sidebar::Section.new(
      "Widgets", ["Buttons", "Inputs", "Slider", "Select box", "Text", "Textarea", "Context menu", "Display", "Color", "Logos", "Hotkeys"],
      closable: true),
    Egui::Sidebar::Section.new(
      "Style", ["Themes", "System styles", "Cursors"], closable: true),
    Egui::Sidebar::Section.new(
      "Containers", ["Scroll", "Modal", "Files"], closable: true),
    Egui::Sidebar::Section.new(
      "Layout", ["Grid", "Table", "Tree", "Plot", "Enabled"], closable: true),
  ]

  COMBO_OPTIONS = ["First", "Second", "Third"]

  # App actions (the hotkey layer is action-driven: menus and the
  # hotkey map reference these, never a key string). The gallery's
  # only hardcoded combos are the DEFAULT_BINDINGS below — everything
  # else picks up rebinds from the Hotkeys tab at runtime.
  ACTION_NEW   = Egui::HotkeyAction.new("app.new_tab")
  ACTION_OPEN  = Egui::HotkeyAction.new("app.open")
  ACTION_QUIT  = Egui::HotkeyAction.new("app.quit")
  ACTION_UNDO  = Egui::HotkeyAction.new("app.undo")
  ACTION_REDO  = Egui::HotkeyAction.new("app.redo")
  ACTION_MODAL = Egui::HotkeyAction.new("app.toggle_modal")
  ACTION_THEME = Egui::HotkeyAction.new("app.toggle_theme")

  # What the Hotkeys tab lists: action + description row.
  HOTKEY_ACTIONS = {
    ACTION_NEW   => "File → New — new tab",
    ACTION_OPEN  => "File → Open…",
    ACTION_QUIT  => "File → Quit",
    ACTION_UNDO  => "Edit → Undo (unbound — try it)",
    ACTION_REDO  => "Edit → Redo",
    ACTION_MODAL => "View → Toggle modal",
    ACTION_THEME => "View → toggle theme",
  }

  DEFAULT_BINDINGS = {
    ACTION_NEW   => "Ctrl+N",
    ACTION_OPEN  => "Ctrl+O",
    ACTION_QUIT  => "Ctrl+Q",
    ACTION_REDO  => "Ctrl+Shift+Z",
    ACTION_MODAL => "Ctrl+M",
    ACTION_THEME => "Ctrl+T",
  }

  def update(ctx : Egui::Context) : Nil
    @updates += 1
    # --styled: swap the whole UI onto the custom stylesheet theme once,
    # before anything renders (screenshots; see #showcase_theme).
    if @styled && !@styled_applied
      ctx.theme = showcase_theme
      @styled_applied = true
    end
    # Default hotkey bindings — once, on the first frame (the map
    # lives on the Context). Rebinds in the Hotkeys tab replace these.
    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end
    # Files dropped onto the window land here for one frame.
    unless ctx.input.dropped_files.empty?
      @dropped = ctx.input.dropped_files.dup
    end

    # Desktop-style menu bar pinned to the top. Items reference
    # actions — the shortcut hint comes from ctx.hotkeys (rebind in
    # the Widgets → Hotkeys tab and watch it update), clicks re-fire
    # the action for #handle_actions below.
    ctx.menu_bar do |bar|
      bar.menu_button("File") do |menu|
        menu.menu_item("New", ACTION_NEW)
        menu.menu_item("Open…", ACTION_OPEN)
        menu.menu_item("Quit", ACTION_QUIT)
      end
      bar.menu_button("Edit") do |menu|
        menu.menu_item("Undo", ACTION_UNDO)
        menu.menu_item("Redo", ACTION_REDO)
      end
      bar.menu_button("View") do |menu|
        menu.menu_item("Toggle modal", ACTION_MODAL)
        # Introspection: the whole style tree (classes → states → keys)
        # goes to stdout — `ctx.stylesheet.dump` accepts any IO.
        menu.menu_item("Dump stylesheet (stdout)") { puts ctx.stylesheet }
        # Instant global theme swap: assigning ctx.theme restyles the
        # whole UI on the next frame.
        menu.menu_item(ctx.theme.dark? ? "Light theme" : "Dark theme",
          ACTION_THEME)
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
        ui.label("Every tab is closed — nowhere to navigate. (File → New adds tabs back.)")
      else
        ui.scroll_area do |scroll|
          scroll.heading(@sections[@section].tabs[@tab])
          scroll.separator

          case {@sections[@section].title, @sections[@section].tabs[@tab]}
          when {"Widgets", "Buttons"}   then buttons_gallery(scroll)
          when {"Widgets", "Inputs"}    then inputs_gallery(scroll)
          when {"Widgets", "Slider"}    then slider_gallery(scroll)
          when {"Widgets", "Select box"} then select_box_gallery(scroll, ctx)
          when {"Widgets", "Text"}      then text_gallery(scroll)
          when {"Widgets", "Textarea"}  then textarea_gallery(scroll)
          when {"Widgets", "Context menu"} then context_menu_gallery(scroll)
          when {"Widgets", "Display"}   then display_gallery(scroll)
          when {"Widgets", "Color"}     then color_gallery(scroll)
          when {"Widgets", "Logos"}     then logos_gallery(scroll)
          when {"Widgets", "Hotkeys"}   then hotkeys_gallery(scroll)
          when {"Style", "Themes"}      then themes_gallery(scroll, ctx)
          when {"Style", "System styles"} then system_styles_gallery(scroll, ctx)
          when {"Style", "Cursors"}     then cursors_gallery(scroll)
          when {"Containers", "Scroll"} then scroll_gallery(scroll)
          when {"Containers", "Modal"}  then modal_gallery(scroll)
          when {"Containers", "Files"}  then files_gallery(scroll)
          when {"Layout", "Grid"}       then grid_gallery(scroll)
          when {"Layout", "Table"}      then table_gallery(scroll)
          when {"Layout", "Tree"}       then tree_gallery(scroll)
          when {"Layout", "Plot"}       then plot_gallery(scroll)
          when {"Layout", "Enabled"}    then enabled_gallery(scroll)
          else
            scroll.label("(a user-created tab — close it with its X)")
          end
        end
      end
    end

    if @modal_open
      clicked = ctx.modal("demo", title: "Modal dialog",
        buttons: ["Close"]) do |ui|
        ui.label("Everything below is blocked while this is open.")
      end
      @modal_open = false if clicked == "Close"
    end

    ctx.bottom_panel("fps") do |ui|
      if @sections.empty?
        ui.label("FPS: #{"%.1f" % ctx.fps}")
      else
        ui.label("FPS: #{"%.1f" % ctx.fps} — " \
                 "#{@sections[@section].title} / #{@sections[@section].tabs[@tab]}")
      end
      # On-demand repaint: the counter only moves when a real update
      # runs (input, animation, dialog) — it freezes while the UI idles.
      ui.label("updates: #{@updates}")
      ui.label("last action: #{@last_action}")
    end

    # Action dispatch: runs AFTER the menu bar so menu-click
    # re-firings (Context#fire_action) land in the same frame, and
    # after the widgets so an open menu's #menu_item gets first claim
    # on hotkey firings. Every trigger has exactly one handler.
    handle_actions(ctx)
  end

  # The single place app actions are handled — hotkey presses and
  # menu clicks both arrive as action events here.
  private def handle_actions(ctx : Egui::Context) : Nil
    if ctx.consume_action(ACTION_NEW)
      @last_action = ACTION_NEW.to_s
      new_tab
    end
    if ctx.consume_action(ACTION_OPEN)
      @last_action = ACTION_OPEN.to_s
    end
    if ctx.consume_action(ACTION_QUIT)
      @last_action = ACTION_QUIT.to_s
      Egui::SystemPorts::Quit.quit!
    end
    if ctx.consume_action(ACTION_UNDO)
      @last_action = ACTION_UNDO.to_s
    end
    if ctx.consume_action(ACTION_REDO)
      @last_action = ACTION_REDO.to_s
    end
    if ctx.consume_action(ACTION_MODAL)
      @last_action = ACTION_MODAL.to_s
      @modal_open = !@modal_open
    end
    if ctx.consume_action(ACTION_THEME)
      @last_action = ACTION_THEME.to_s
      ctx.theme = ctx.theme.dark? ? Egui::Theme.light : Egui::Theme.dark
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

  # File → New: append a fresh "tab <n>" to the current section and
  # select it (a brand-new "Tabs" section when every section was closed).
  private def new_tab : Nil
    title = "tab #{@next_tab}"
    @next_tab += 1

    if @sections.empty?
      @sections << Egui::Sidebar::Section.new("Tabs", [title], closable: true)
      @section = 0
      @tab = 0
    else
      section = @sections[@section]
      tabs = section.tabs.dup << title
      @sections[@section] = Egui::Sidebar::Section.new(section.title, tabs,
        closable: true)
      @tab = tabs.size - 1
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
      # the theme value), so the background stays custom across theme
      # swaps while the stroke/text follow the theme. The inline
      # background is FLAT across states (CSS inline-style semantics);
      # per-state colors live in class rules
      # (`ctx.stylesheet.rule("button:hover", …)`).
      row.add(Egui::Button.new("Themed red").style do |s|
        s.background = Egui::Color32.rgb(170, 40, 40)
      end)
    end
    # Provider icons (icons/lucide, ISC): `Icon.from_file` embeds
    # just the referenced SVGs into the binary at compile time and
    # resolves the set's `currentColor` through `tint:`.
    ui.label("Provider icon buttons (lucide):")
    ui.horizontal do |row|
      fg = row.style.visuals.text_color
      row.add(Egui::Button.new("Save")
        .icon(Egui::Icon.from_file(:lucide, :save, tint: fg)))
      row.add(Egui::Button.new("Open")
        .icon(Egui::Icon.from_file(:lucide, :folder_open, tint: fg)))
      row.add(Egui::Button.new("Download")
        .icon(Egui::Icon.from_file(:lucide, :download, tint: fg)))
      row.add(Egui::Button.new("Delete")
        .icon(Egui::Icon.from_file(:lucide, :trash, tint: fg)))
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

    ui.label("Drag value (sliders live in their own tab now):")
    ui.drag_value(@drag, speed: 0.1, suffix: " px") { |v| @drag = v }
    ui.separator

    ui.label("Number input (integers only, up/down spin):")
    ui.horizontal do |row|
      row.number_input(@spin, 0..100, suffix: " pt") { |v| @spin = v }
      row.number_input(@spin, 0..100, step: 5) { |v| @spin = v }
    end
    ui.separator

    ui.label("Combo / text edit:")
    # zero state: nothing selected — the placeholder shows until a pick
    ui.combo_box("gallery_combo", @combo_none, COMBO_OPTIONS,
      label: "Select option") { |opt| @combo_none = opt }
    # GTK3 style: the list opens right on top of the button, with the
    # placeholder leading it — picking that row clears the selection
    ui.combo_box("gallery_combo_gtk", @combo_none, COMBO_OPTIONS,
      label: "Select option", overlay: true) { |opt| @combo_none = opt }
    # input-field look with a select button
    ui.combo_box("gallery_combo_field", @combo, COMBO_OPTIONS,
      variant: :field) { |opt| @combo = opt }
    # rigid single button, chevron inline (no separated strip)
    ui.combo_box("gallery_combo_plain", @combo, COMBO_OPTIONS,
      variant: :plain) { |opt| @combo = opt }
    ui.text_edit_singleline(@buffer, hint: "type here…") { |t| @buffer = t }
    ui.text_edit_singleline(@buffer2) { |t| @buffer2 = t }
    ui.label("(select with Shift+arrows or double-click / drag; Ctrl+A/C/X/V)")
    ui.separator

    ui.label("Password field (circles instead of characters):")
    ui.text_edit_singleline(@password, hint: "password…",
      password: true) { |t| @password = t }
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

  # The Slider tab: every slider variation in one place — plain,
  # unlabeled, with macOS-style tips under the rail, and quantized
  # (the value restricted to a fixed list the handle snaps onto).
  private def slider_gallery(ui : Egui::Ui) : Nil
    ui.label("Plain slider (label + live value):")
    ui.slider(@slider, 0.0..1.0, "Opacity") { |v| @slider = v }
    ui.separator

    ui.label("No label:")
    ui.slider(@slider_nt, 0.0..1.0) { |v| @slider_nt = v }
    ui.separator

    # macOS-style: `tips:` paints the pair under the rail, flush to its
    # ends — the left one left-aligned, the right one right-aligned.
    ui.label("Tips (macOS-style captions under the rail):")
    ui.slider(@slider_tips, 0.0..100.0, "Volume",
      tips: {"Quiet", "Loud"}) { |v| @slider_tips = v }
    ui.separator

    # `quantized: true` requires `values:` — the pointer maps to the
    # nearest entry and the handle sits at discrete index positions.
    ui.label("Quantized (value restricted to a list):")
    ui.slider(@slider_q, 0.0..1.0, "Steps",
      quantized: true, values: [0.0, 0.25, 0.5, 0.75, 1.0]) { |v| @slider_q = v }
    ui.separator

    # `ticks: true` — macOS-style vertical strokes under the rail, one
    # per entry, pointing at the quants (stylable as `slider.tick`).
    ui.label("Quantized + tick marks (macOS strokes at the quants):")
    ui.slider(@slider_tick, 0.0..1.0, "Steps",
      quantized: true, ticks: true,
      values: [0.0, 0.25, 0.5, 0.75, 1.0]) { |v| @slider_tick = v }
    ui.separator

    ui.label("Quantized + ticks + tips:")
    ui.slider(@slider_qt, 0.0..1.0, "Quality",
      tips: {"Low", "High"}, quantized: true, ticks: true,
      values: [0.0, 0.5, 1.0]) { |v| @slider_qt = v }
  end

  # The SelectBox tab: a searchable select over the font family
  # catalog — every family the app loaded plus the system scan's
  # deferred families (a family parses on first pick, so a catalog of
  # ~1500 names costs nothing until used). Picking swaps the preview
  # labels' font live: system → the primary stack, a named family →
  # its own stack.
  private def select_box_gallery(ui : Egui::Ui, ctx : Egui::Context) : Nil
    ui.label("A select box with built-in search — click, type, pick:")
    ui.horizontal do |row|
      row.select_box("gallery_font", @font_family,
        ctx.font_family_catalog, 240.0,
        label: "(system default)") { |opt| @font_family = opt }
      # font size for the preview, 10..32 px
      row.select_box("gallery_size", @font_size.to_i.to_s,
        (10..32).map(&.to_s), 70.0) { |opt| @font_size = opt.to_f }
    end
    ui.label("(the list scrolls; the filter narrows it as you type; " \
             "the highlighted row is what Enter confirms; " \
             "the placeholder row resets the selection)")
    ui.separator

    ui.label("Preview — the picked family and size applied live:")
    preview = "The quick brown fox jumps over the lazy dog 0123 — #{@font_family}"
    ui.add(Egui::Label.new(preview, wrap: true)
      .style { |s| s.font_family = @font_family; s.font_size = @font_size })
    ui.add(Egui::Label.new("1234567890 !?%&()[]{}")
      .style { |s| s.font_family = @font_family; s.font_size = @font_size })
    ui.separator

    ui.label("A short static list works too (no filter needed " \
             "to find anything):")
    ui.select_box("gallery_small", @combo, COMBO_OPTIONS, 160.0,
      label: "Select option") { |opt| @combo = opt }
  end

  private def text_gallery(ui : Egui::Ui) : Nil
    ui.rich(Egui::RichText.new("rich underlined")
      .color(Egui::Color32.rgb(255, 96, 96)).underline)
    ui.hyperlink_to("egui on GitHub", "https://github.com/emilk/egui")
    ui.label("Hover me").on_hover_text("Tooltips work!")
    ui.label("This long paragraph wraps because the label asked for it — resize the window and watch it reflow.", wrap: true)
  end

  # HTML <textarea>: soft wrap, kinetic wheel scrolling when the text
  # outgrows the box, per-line selection, Enter/arrows/Home/End.
  private def textarea_gallery(ui : Egui::Ui) : Nil
    ui.label("Multiline editor — flick the wheel inside it to feel the kinetic scroll.")
    ui.textarea(@ta_text, rows: 14) { |t| @ta_text = t }
    ui.separator
    ui.label("#{@ta_text.count('\n') + 1} lines, #{@ta_text.size} bytes")
  end

  # Class-based context menus: a reusable `Egui::ContextMenu` attached
  # to a widget through `Response#context_menu` — a secondary press
  # opens it at the pointer. Rows carry vector icons and hotkey hints
  # (static strings, or live ones via actions — the Undo/Redo rows
  # follow the Hotkeys tab rebinds).
  private def context_menu_gallery(ui : Egui::Ui) : Nil
    ui.label("Right-click each widget — it carries its own class-built context menu:")
    ui.label("last fired: #{@last_action}")
    ui.separator

    ui.label("Textarea (clipboard actions + clear):")
    ui.textarea(@ta_text, rows: 6) { |t| @ta_text = t }
      .context_menu(text_menu)
    ui.separator

    ui.label("Text input (action rows with live hotkey hints):")
    ui.text_edit_singleline(@buffer) { |t| @buffer = t }
      .context_menu(input_menu)
    ui.separator

    ui.label("Buttons (both share one menu instance):")
    ui.horizontal do |row|
      row.button("Button A").context_menu(button_menu)
      row.button("Button B").context_menu(button_menu)
    end
  end

  # The menus are built once (lazy ivars) — handlers capture app state,
  # so rebuilding them per frame would churn closures for nothing.
  private def text_menu : Egui::ContextMenu
    @text_menu ||= Egui::ContextMenu.new
      .item("Copy all", icon: :copy, hotkey: "Ctrl+C") do
        Egui::SystemPorts::Clipboard.text = @ta_text
        @last_action = "context: copy textarea"
      end
      .item("Paste at end", icon: :paste, hotkey: "Ctrl+V") do
        @ta_text = @ta_text.empty? ? Egui::SystemPorts::Clipboard.text.to_s :
          "#{@ta_text}\n#{Egui::SystemPorts::Clipboard.text}"
        @last_action = "context: paste textarea"
      end
      .separator
      .item("Clear", icon: :trash) do
        @ta_text = ""
        @last_action = "context: clear textarea"
      end
  end

  private def input_menu : Egui::ContextMenu
    @input_menu ||= Egui::ContextMenu.new
      .item("Undo", icon: :left, action: ACTION_UNDO)
      .item("Redo", icon: :right, action: ACTION_REDO)
      .separator
      .item("Copy", icon: :copy, hotkey: "Ctrl+C") do
        Egui::SystemPorts::Clipboard.text = @buffer
        @last_action = "context: copy input"
      end
      .item("Paste", icon: :paste, hotkey: "Ctrl+V") do
        @buffer = Egui::SystemPorts::Clipboard.text.to_s
        @last_action = "context: paste input"
      end
  end

  private def button_menu : Egui::ContextMenu
    @button_menu ||= Egui::ContextMenu.new
      .item("Confirm", icon: :check) { @last_action = "context: confirmed" }
      .item("Cancel", icon: :close) { @last_action = "context: cancelled" }
      .separator
      .item("New tab", icon: :plus, action: ACTION_NEW)
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

  # Egui::Svg: the logo.svg design (letter E) in several variants —
  # parsed from SVG source and painted as vectors, live-rescaled.
  private def logos_gallery(ui : Egui::Ui) : Nil
    ui.label("SVG widget — logo.svg variants with the letter E:")
    ui.horizontal do |row|
      row.label("size:")
      row.slider(@logo_size, 24.0..160.0) { |v| @logo_size = v }
    end
    ui.separator
    ui.grid("logos_grid") do |grid|
      LOGO_VARIANTS.each do |name, source|
        grid.add(Egui::Svg.new(source, Egui::Vec2.new(@logo_size, @logo_size)))
        grid.label(name)
        grid.end_row
      end
    end
  end

  # The global hotkey map: every app action with a HotkeyEdit bound
  # to it. Rebinding here updates the menu bar's shortcut hints on
  # the next frame — the menus reference actions, not key strings.
  private def hotkeys_gallery(ui : Egui::Ui) : Nil
    ui.label("Global hotkey map (ctx.hotkeys) — action-driven, no hardcoded combos:")
    ui.label("last action fired: #{@last_action}")
    ui.separator
    HOTKEY_ACTIONS.each do |action, desc|
      ui.horizontal do |row|
        row.label(desc)
        row.hotkey_edit(action) { |hotkey| }
      end
    end
    ui.separator
    ui.label("Click a button, then press a key combo (Esc cancels, Backspace clears).")
    ui.label("Check the File menu — its hints follow these bindings live.")
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

  # System-style presets: whole themes derived from the defaults via
  # `DefaultTheme.build` with a custom palette — the block runs before
  # the element rules, so the button/sidebar classes adopt the preset
  # colors too. A click assigns `ctx.theme`; the whole app (menu bar,
  # sidebar, window title strip included) repaints on the next frame.
  private def system_styles_gallery(ui : Egui::Ui, ctx : Egui::Context) : Nil
    ui.label("System-style themes — pick one to restyle the whole app:")
    system_themes.each do |theme|
      ui.horizontal do |row|
        if row.radio(ctx.theme.same?(theme), theme.name).changed?
          ctx.theme = theme
        end
        row.label(theme.dark? ? "dark" : "light")
      end
    end
    ui.separator

    # Live preview strip: everything below follows the active theme
    # with no per-widget setup — swap presets above and watch it flip.
    ui.label("Preview (follows the active theme):")
    ui.horizontal do |row|
      row.button("Button")
      cb = row.add(Egui::Checkbox.new(@checked, "Check"))
      @checked = !@checked if cb.changed?
      row.slider(@slider, 0.0..1.0) { |v| @slider = v }
    end
    ui.horizontal do |row|
      row.label("Progress:")
      row.progress_bar(@slider.clamp(0.0, 1.0))
      row.hyperlink_to("a link", "https://github.com/emilk/egui")
    end
    ui.separator
    ui.label("active: #{ctx.theme}")
  end

  # The preset list, built once: the two built-in presets plus the four
  # system styles below. Theme instances are stateful (the Themes tab
  # can tweak their sheet live), so they are cached, not rebuilt.
  private def system_themes : Array(Egui::Theme)
    @system_themes ||= [
      Egui::Theme.dark,
      Egui::Theme.light,
      ubuntu_theme,
      windows_xp_theme,
      windows_11_theme,
      macos_theme,
    ]
  end

  # The --styled showcase: one derived theme restyles EVERY widget —
  # palette through `DefaultTheme.build`'s block, then CSS-cascade class
  # rules on top (button paddings, sidebar selection, tab underlines,
  # link color). Nothing per-widget: the sheet reaches everything.
  private def showcase_theme : Egui::Theme
    accent = Egui::Color32.rgb(0x7C, 0x4D, 0xFF) # violet
    theme = Egui::DefaultTheme.build("showcase", dark: true) do |v|
      v.window_fill = Egui::Color32.rgb(24, 22, 34)
      v.panel_fill = Egui::Color32.rgb(18, 16, 26)
      v.selection_fill = accent
      v.hyperlink_color = Egui::Color32.rgb(0x5E, 0xD3, 0xB8) # teal
      v.button_stroke = Egui::Color32.rgb(110, 96, 160)
    end
    sheet = theme.sheet
    sheet.rule("button", Egui::StyleVars{
      "padding.top"    => 7.0,
      "padding.right"  => 14.0,
      "padding.bottom" => 7.0,
      "padding.left"   => 14.0,
    })
    sheet.rule("button:hover", Egui::StyleVars{
      "background" => Egui::Color32.rgba(124, 77, 255, 120),
    })
    sheet.rule("sidebar.tab:selected", Egui::StyleVars{
      "background" => accent,
      "text_color" => Egui::Color32.rgb(255, 255, 255),
    })
    sheet.rule("tabs.tab:selected", Egui::StyleVars{
      "underline_color" => Egui::Color32.rgb(0x5E, 0xD3, 0xB8),
      "underline_width" => 3.0,
    })
    theme
  end

  # Preset colors are 1:1 from the platforms' own theme sources (values
  # in brackets). Alpha-blended tokens (WinUI's 70% white fills, macOS's
  # 85% black label) are pre-composited over their theme background —
  # Visuals has no per-color alpha compositing over arbitrary surfaces.

  # Ubuntu — Yaru light, from the yaru repo sass
  # (gtk/src/default/gtk-3.0/{_palette,_colors}.scss): bg #FAFAFA, fg
  # $inkstone #3D3D3D, base #FFFFFF, borders darken(bg,20%) #C7C7C7,
  # headerbar lighten(bg,5%) #FFFFFF, accent $orange #E95420 (selected
  # bg + accent fg white). Buttons are Adwaita's: bg-colored, hover
  # darken(bg,4%), active darken(bg,8%). Window corner radius follows
  # libadwaita (12px).
  private def ubuntu_theme : Egui::Theme
    Egui::DefaultTheme.build("Ubuntu", dark: false) do |v|
      v.window_fill = Egui::Color32.rgb(0xFA, 0xFA, 0xFA) # $bg_color
      v.window_stroke = Egui::Color32.rgb(0xC7, 0xC7, 0xC7) # $borders_color
      v.title_bar_fill = Egui::Color32.rgb(0xFF, 0xFF, 0xFF) # $headerbar_color
      v.title_color = Egui::Color32.rgb(0x3D, 0x3D, 0x3D)   # $inkstone
      v.window_rounding = 12.0
      v.panel_fill = Egui::Color32.rgb(0xFF, 0xFF, 0xFF) # $base_color
      v.text_color = Egui::Color32.rgb(0x3D, 0x3D, 0x3D)  # $fg_color
      v.button_weak = Egui::Color32.rgb(0xFA, 0xFA, 0xFA)
      v.button_hovered = Egui::Color32.rgb(0xF0, 0xF0, 0xF0) # darken(bg, 4%)
      v.button_active = Egui::Color32.rgb(0xE6, 0xE6, 0xE6)  # darken(bg, 8%)
      v.button_stroke = Egui::Color32.rgb(0xC7, 0xC7, 0xC7)  # $borders_color
      v.selection_fill = Egui::Color32.rgb(0xE9, 0x54, 0x20) # $accent_bg_color
      # Yaru derives links from the accent (optimize-contrast over bg)
      v.hyperlink_color = Egui::Color32.rgb(0xE9, 0x54, 0x20)
      v.separator_color = Egui::Color32.rgb(0xC7, 0xC7, 0xC7)
    end
  end

  # Windows XP — Luna Blue, from XP.css v0.2.6 (a 1:1 msstyles
  # extraction) plus the documented registry scheme: face #ECE9D8,
  # title bar gradient (0997ff→0053ee→0050ee→06f→003dd7) flattened to
  # its dominant stop #0050EE, window frame #003BDA, Hilight #316AC5,
  # WindowText #000000, ButtonShadow #ACA899. Luna buttons are
  # border-drawn (grey/white outset), so the stroke carries the look;
  # hover/active fills are flat stand-ins for the amber hover glow.
  private def windows_xp_theme : Egui::Theme
    theme = Egui::DefaultTheme.build("Windows XP", dark: false) do |v|
      v.window_fill = Egui::Color32.rgb(0xEC, 0xE9, 0xD8) # button/dialog face
      v.window_stroke = Egui::Color32.rgb(0x00, 0x3B, 0xDA)
      v.title_bar_fill = Egui::Color32.rgb(0x00, 0x50, 0xEE)
      v.title_color = Egui::Color32.rgb(0xFF, 0xFF, 0xFF)
      v.window_rounding = 0.0
      v.panel_fill = Egui::Color32.rgb(0xEF, 0xEB, 0xD4) # page background
      v.text_color = Egui::Color32.rgb(0x00, 0x00, 0x00) # WindowText
      v.button_weak = Egui::Color32.rgb(0xEC, 0xE9, 0xD8)
      v.button_hovered = Egui::Color32.rgb(0xF1, 0xEE, 0xE0)
      v.button_active = Egui::Color32.rgb(0xDE, 0xDA, 0xC9)
      v.button_stroke = Egui::Color32.rgb(0xAC, 0xA8, 0x99) # ButtonShadow
      v.selection_fill = Egui::Color32.rgb(0x31, 0x6A, 0xC5) # Hilight
      v.hyperlink_color = Egui::Color32.rgb(0x00, 0x00, 0xFF)
      v.separator_color = Egui::Color32.rgb(0xAC, 0xA8, 0x99)
    end

    # Classic Win32 tab sheets: the ACTIVE tab takes the PAGE color and
    # merges with it — no accent underline, the baseline skips its span
    # (merge_selected), and it is framed by the registry bevel pair
    # ButtonHilight #FFF / ButtonShadow #ACA899. Inactive tabs keep the
    # dialog face — one step darker, they read as sitting behind.
    face = Egui::Color32.rgb(0xEC, 0xE9, 0xD8)
    page = Egui::Color32.rgb(0xEF, 0xEB, 0xD4)
    shadow = Egui::Color32.rgb(0xAC, 0xA8, 0x99)
    sheet = theme.sheet
    sheet.rule("tabs", Egui::StyleVars{
      "merge_selected" => 1.0,
      "rule_color"     => shadow,
    })
    sheet.rule("tabs.tab", Egui::StyleVars{
      "fill"        => face,
      "bevel_light" => Egui::Color32.rgb(0xFF, 0xFF, 0xFF),
      "bevel_dark"  => shadow,
    })
    sheet.rule("tabs.tab:selected", Egui::StyleVars{
      "fill"            => page,
      "underline_width" => 0.0,
    })
    # Sidebar nav follows the same metaphor: the selected tab merges
    # into the page background (black text — the default rule's white
    # would be unreadable on the cream); hover keeps the warm wash.
    sheet.rule("sidebar.tab:selected", Egui::StyleVars{
      "fill"       => page,
      "text_color" => Egui::Color32.rgb(0x00, 0x00, 0x00),
    })
    # Checkbox/radio mark AREA takes the dialog face (XP.css keeps the
    # checkbox interior face-colored while pressed/disabled) with the
    # registry ButtonShadow border and square corners — the mark itself
    # stays WindowText black; a face-colored mark would vanish into the
    # face-colored box. Pinning box_fill also drops the idle→hover
    # lighten (XP boxes do not shift on hover).
    sheet.rule("checkbox", Egui::StyleVars{
      "box_fill"    => face,
      "box_stroke"  => shadow,
      "check_color" => Egui::Color32.rgb(0x00, 0x00, 0x00),
      "rounding"    => 0.0,
    })
    theme
  end

  # Windows 11 — light, from the WinUI theme tokens (verbatim in
  # FluentAvalonia's Fluentv2Colors.axaml): mica base #F3F3F3
  # (SolidBackgroundFillColorBase), content #F9F9F9 (…Tertiary),
  # ControlFillColorDefault 70% white → #FDFDFD, Secondary (hover)
  # 50% #F9F9F9 → #F9F9F9, Tertiary (pressed) over base → #F5F5F5,
  # border ControlStrokeColorSecondary 16% black → #D6D6D6, divider
  # 6% black → #EAEAEA, modal SmokeFillColorDefault 30% black.
  # Accent = AccentFillColorDefault light #005FB8; text =
  # TextFillColorPrimary 89% black → #1A1A1A.
  private def windows_11_theme : Egui::Theme
    Egui::DefaultTheme.build("Windows 11", dark: false) do |v|
      v.window_fill = Egui::Color32.rgb(0xF3, 0xF3, 0xF3)
      v.window_stroke = Egui::Color32.rgb(0xEB, 0xEB, 0xEB) # CardStroke…Solid
      v.title_bar_fill = v.window_fill
      v.title_color = Egui::Color32.rgb(0x1A, 0x1A, 0x1A)
      v.window_rounding = 8.0
      v.panel_fill = Egui::Color32.rgb(0xF9, 0xF9, 0xF9)
      v.text_color = Egui::Color32.rgb(0x1A, 0x1A, 0x1A)
      v.button_weak = Egui::Color32.rgb(0xFD, 0xFD, 0xFD)
      v.button_hovered = Egui::Color32.rgb(0xF9, 0xF9, 0xF9)
      v.button_active = Egui::Color32.rgb(0xF5, 0xF5, 0xF5)
      v.button_stroke = Egui::Color32.rgb(0xD6, 0xD6, 0xD6)
      v.selection_fill = Egui::Color32.rgb(0x00, 0x5F, 0xB8)
      v.hyperlink_color = Egui::Color32.rgb(0x00, 0x5F, 0xB8)
      v.separator_color = Egui::Color32.rgb(0xEA, 0xEA, 0xEA)
      v.modal_dim = Egui::Color32.rgba(0, 0, 0, 0x4D)
    end
  end

  # macOS — light, from the NSColor export (swiftuicolors.com):
  # window chrome #ECECEC, content controlBackgroundColor #FFFFFF,
  # controlColor (button surface) #FFFFFF, hover tertiarySystemFill 5%
  # black → #F2F2F2, pressed secondarySystemFill 8% → #EBEBEB, label
  # rgba(0,0,0,0.85) → #262626, windowFrameText 85% over chrome →
  # #232323, controlAccentColor #007AFF, linkColor #0068DA,
  # gridColor #E6E6E6, control border tertiaryLabel rgba(60,60,67,.26)
  # → #CCCCCC, window edge quaternaryLabel .18 → #DCDCDD.
  # Window corner radius 10 (Big Sur+).
  private def macos_theme : Egui::Theme
    Egui::DefaultTheme.build("macOS", dark: false) do |v|
      v.window_fill = Egui::Color32.rgb(0xEC, 0xEC, 0xEC)
      v.window_stroke = Egui::Color32.rgb(0xDC, 0xDC, 0xDD)
      v.title_bar_fill = v.window_fill # merged titlebar
      v.title_color = Egui::Color32.rgb(0x23, 0x23, 0x23)
      v.window_rounding = 10.0
      v.panel_fill = Egui::Color32.rgb(0xFF, 0xFF, 0xFF)
      v.text_color = Egui::Color32.rgb(0x26, 0x26, 0x26)
      v.button_weak = Egui::Color32.rgb(0xFF, 0xFF, 0xFF)
      v.button_hovered = Egui::Color32.rgb(0xF2, 0xF2, 0xF2)
      v.button_active = Egui::Color32.rgb(0xEB, 0xEB, 0xEB)
      v.button_stroke = Egui::Color32.rgb(0xCC, 0xCC, 0xCC)
      v.selection_fill = Egui::Color32.rgb(0x00, 0x7A, 0xFF)
      v.hyperlink_color = Egui::Color32.rgb(0x00, 0x68, 0xDA)
      v.separator_color = Egui::Color32.rgb(0xE6, 0xE6, 0xE6)
    end
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
    ui.label("Scroll area (wheel me) — overlay scrollbar:")
    ui.scroll_area(max_height: 300.0) do |inner|
      25.times { |i| inner.label("scroll row #{i}") }
    end
    ui.separator
    # scrollbar: :classic — a separate Win95/XP-style column with
    # arrow buttons and a paging track, beside (not over) the content.
    ui.label("Classic scrollbar (Win95/XP: arrows, page-on-track):")
    ui.scroll_area(max_height: 300.0, scrollbar: :classic) do |inner|
      25.times { |i| inner.label("classic row #{i}") }
    end
    ui.separator
    # vbar: :left — same overlay bar, pinned to the left edge (the
    # Sidebar uses this: away from the tabs' close buttons).
    ui.label("Overlay scrollbar on the left (sidebar-style):")
    ui.scroll_area(max_height: 150.0, vbar: :left) do |inner|
      12.times { |i| inner.label("left-bar row #{i}") }
    end
    ui.separator
    # hbar: :bottom / :top — horizontal scrolling. Shift+wheel drives
    # the horizontal axis; the thumb is draggable too.
    ui.label("Horizontal bar at the bottom (Shift+wheel):")
    ui.scroll_area(max_height: 80.0, hbar: :bottom) do |inner|
      inner.label("left end → " + ("walk " * 200) + "← right end")
    end
    ui.separator
    ui.label("Horizontal classic bar at the top:")
    ui.scroll_area(max_height: 80.0, scrollbar: :classic, hbar: :top) do |inner|
      inner.label("left end → " + ("walk " * 200) + "← right end")
    end
  end

  private def modal_gallery(ui : Egui::Ui) : Nil
    ui.label("Modal dialog:")
    ui.label("Everything below is blocked while it is open — open it from here or from the Buttons tab.")
    if ui.button("Open modal").clicked?
      @modal_open = true
    end
  end

  # Aligned columns: column widths are measured frame N and applied
  # frame N+1 (persisted per grid in Memory), like upstream egui Grid.
  # Drag & drop: whatever lands on the window shows up here — file name
  # plus full path (selectable for manual copy) and a reveal-in-explorer
  # button (SystemPorts::RevealInFolder).
  private def files_gallery(ui : Egui::Ui) : Nil
    ui.label("Drop files from Explorer/Finder anywhere onto this window.")
    ui.separator
    if @dropped.empty?
      ui.label("(nothing dropped yet)")
    else
      @dropped.each do |path|
        ui.horizontal do |row|
          row.label(File.basename(path))
          if row.button("Reveal").clicked?
            Egui::SystemPorts::RevealInFolder.show(path)
          end
          if row.button("Copy path").clicked?
            Egui::SystemPorts::Clipboard.text = path
          end
        end
        ui.selectable_label(false, path)
      end
    end
  end

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
    ui.label("Table (header + striped rows, on Grid):")
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
    ui.label("Plot (drag to pan, wheel to zoom; the reset pill appears once \
the view is panned/zoomed):")
    # sin_points/peak_points are computeds — the arrays are built on
    # first read only, not every frame.
    ui.plot("gallery_plot", height: 220) do |p|
      p.line("sin(x)", sin_points)
      p.points("peaks", peak_points)
    end

    ui.label("Same plot with reset_button: false — pan/zoom works, but there \
is no way back (no pill, no double-click reset):")
    ui.plot("gallery_plot_noreset", height: 220, reset_button: false) do |p|
      p.line("sin(x)", sin_points, color: Egui::Color32.rgb(80, 140, 220))
      p.points("peaks", peak_points)
    end

    ui.separator
    ui.label("Animated plot — emulated CPU load, last 60 s, scrolling left → right:")
    now = ui.ctx.input.time
    # There is no delayed repaint, so while this tab is shown keep
    # frames coming (spinner trick) — the window slides every frame.
    ui.ctx.request_repaint
    # Drop samples that fell out of the window, then build the curve:
    # a point every 0.25 s across [now-60, now].
    floor = now.floor.to_i
    @cpu_samples.reject! { |sec, _| sec < floor - 65 }
    pts = [] of {Float64, Float64}
    x = now - 60.0
    while x <= now
      pts << {x, cpu_value(x)}
      x += 0.25
    end
    pts << {now, cpu_value(now)}
    ui.plot("cpu_plot", height: 220, animated: true) do |p|
      # Fixed 0..100% y and a sliding x window — auto-fit would wobble.
      # Pan/zoom freezes the view and shows the reset pill;
      # the pill or a double-click returns to the live default.
      p.fixed_bounds(now - 60.0, 0.0, now, 100.0)
      p.reset_label("Reset CPU view")
      p.line("CPU %", pts, color: Egui::Color32.rgb(120, 180, 60))
    end
    ui.label("current: #{"%.0f" % cpu_value(now)}%")

    ui.separator
    ui.label("Same animated plot with draggable: false — the view is pinned to \
the default, no pan/zoom and no reset pill:")
    ui.plot("cpu_plot_locked", height: 220, animated: true,
      draggable: false) do |p|
      p.fixed_bounds(now - 60.0, 0.0, now, 100.0)
      p.line("CPU % (read-only)", pts, color: Egui::Color32.rgb(210, 80, 80))
    end
  end

  # The emulated load for whole second `sec`: mean-reverting random walk
  # with occasional spikes, clamped to 0..100%.
  private def cpu_at(sec : Int32) : Float64
    @cpu_samples[sec] ||= begin
      prev = @cpu_samples[sec - 1]? || 50.0
      walk = prev + (rand - 0.5) * 20.0 + (50.0 - prev) * 0.1
      spike = rand < 0.07 ? rand * 35.0 : 0.0
      (walk + spike).clamp(0.0, 100.0)
    end
  end

  # Smooth value at fractional time `x`: smoothstep ease between the two
  # neighboring whole-second samples — this is what makes the curve glide
  # instead of stepping once per second.
  private def cpu_value(x : Float64) : Float64
    sec = x.floor.to_i
    f = x - sec
    a = cpu_at(sec)
    b = cpu_at(sec + 1)
    t = f * f * (3.0 - 2.0 * f)
    a + (b - a) * t
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
  width: 900, height: 700,
  icon: {rgba: ICON_64_RGBA, width: 64, height: 64}, inspector: :hidden)
