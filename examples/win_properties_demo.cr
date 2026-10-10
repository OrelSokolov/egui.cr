# Windows-Properties-style tab strip with a full Win95 look: silver
# (#C0C0C0) chrome, navy title bar, teal desktop, 3D beveled tabs and
# buttons, white checkbox boxes, black text. The theme is assembled
# entirely through the public styling API (`DefaultTheme.build` +
# `Theme#style.visuals` + stylesheet rules), including the engine's
# classic-skin keys:
#
#   tabs.tab  bevel_light/bevel_dark  — raised 3D tab border
#   tabs      merge_selected          — the baseline skips the active
#                                       tab, connecting it to the page
#   tabs.tab:selected underline_width = 0 — no underline, Win95-style
#   button    bevel_light/bevel_dark/rounding — beveled command
#                                       buttons (button:active swaps
#                                       the bevel → sunken)
#   checkbox  box_fill/box_stroke/rounding/check_color
#   Visuals   title_bar_fill/window_rounding — navy square title bar
#
# `layout: :multiline` wraps full rows — one line of tabs fills up,
# the next starts below it. Toggle the checkbox to compare with the
# default `:carousel` (one scrolling row) on the same tab set.

require "../src/egui/backend_selector"

module Win95
  SILVER = Egui::Color32.rgb(192, 192, 192)
  WHITE  = Egui::Color32.rgb(255, 255, 255)
  BLACK  = Egui::Color32.rgb(0, 0, 0)
  DKGRAY = Egui::Color32.rgb(128, 128, 128) # the classic 3D shadow
  NAVY   = Egui::Color32.rgb(0, 0, 128)     # active title bar
  TEAL   = Egui::Color32.rgb(0, 128, 128)   # the desktop

  # Assemble the classic theme from the light preset — only the
  # palette and the classic-skin class rules differ.
  def self.theme : Egui::Theme
    theme = Egui::DefaultTheme.build("win95", dark: false)
    v = theme.style.visuals
    v.window_fill = SILVER
    v.window_stroke = BLACK
    v.window_rounding = 0.0
    v.title_bar_fill = NAVY
    v.title_color = WHITE
    v.panel_fill = TEAL
    v.text_color = BLACK
    v.button_weak = SILVER
    v.button_hovered = SILVER
    v.button_active = SILVER
    v.selection_fill = NAVY
    v.separator_color = DKGRAY

    sheet = theme.sheet

    # Tab strip: silver surface, dark baselines, and the active tab
    # merging into the page (no underline, baseline gap under it).
    sheet.rule("tabs", Egui::StyleVars{
      "background"       => SILVER,
      "rule_color"     => DKGRAY,
      "merge_selected" => 1.0,
    })
    sheet.rule("tabs.tab", Egui::StyleVars{
      "background"       => SILVER,
      "text_color"      => BLACK,
      "bevel_light"     => WHITE,
      "bevel_dark"      => DKGRAY,
      "padding.top"     => 4.0,
      "padding.right"   => 12.0,
      "padding.bottom"  => 4.0,
      "padding.left"    => 12.0,
    })
    # :hover/:selected inherit the base rule (no hover state in Win95)
    # — the overlays must re-pin the fill to silver, or the DEFAULT
    # theme's selected overlay (button_hovered ≈ #D1D1D1) leaks through
    # and the active tab no longer matches the page below it.
    sheet.rule("tabs.tab:hover", Egui::StyleVars{
      "background" => SILVER,
    })
    sheet.rule("tabs.tab:selected", Egui::StyleVars{
      "background"       => SILVER,
      "underline_width" => 0.0,
    })

    # Command buttons: silver with a raised bevel; :active swaps the
    # bevel colors → sunken, like a pressed Win95 button.
    sheet.rule("button", Egui::StyleVars{
      "background"       => SILVER,
      "text_color"      => BLACK,
      "rounding"        => 0.0,
      "bevel_light"     => WHITE,
      "bevel_dark"      => DKGRAY,
      "padding.top"     => 4.0,
      "padding.right"   => 14.0,
      "padding.bottom"  => 4.0,
      "padding.left"    => 14.0,
    })
    sheet.rule("button:active", Egui::StyleVars{
      "bevel_light" => DKGRAY,
      "bevel_dark"  => WHITE,
    })

    # Checkbox: white box, black border and check (a shade sunken from
    # the silver dialog face).
    sheet.rule("checkbox", Egui::StyleVars{
      "box_fill"    => WHITE,
      "box_stroke"  => BLACK,
      "rounding"    => 0.0,
      "check_color" => BLACK,
    })

    theme
  end
end

class WinPropertiesDemo < Egui::App
  # A property-sheet-worthy tab count — at the demo window's width
  # this wraps onto three lines.
  TABS = ["General", "Sharing", "Security", "Details", "Previous Versions",
          "Permissions", "Auditing", "Owner", "Effective Access",
          "Shortcut", "Events", "Statistics"]

  # Real key/value rows for a few tabs; the rest get a generic pair.
  PROPS = {
    "General"  => {
      "Type"     => "File (text/x-crystal)",
      "Location" => "/home/oleg/egui.cr",
      "Size"     => "12.4 KB (12,698 bytes)",
      "Created"  => "today, by rake build:examples",
    },
    "Security" => {
      "Owner" => "oleg",
      "Group" => "oleg",
      "Mode"  => "rw-r--r--",
    },
    "Details"  => {
      "Origin" => "egui.cr (local)",
      "Tabs"   => "#{TABS.size} (wrapped into several rows)",
      "Layout" => ":multiline (Windows Properties style)",
    },
  }

  @tab = 0
  @layout = :multiline
  @applied = "not applied yet"
  @themed = false

  def update(ctx : Egui::Context) : Nil
    unless @themed
      ctx.theme = Win95.theme
      @themed = true
    end

    # The teal desktop the dialog floats over.
    ctx.central_panel { }

    # Real properties dialogs are small, fixed-ish windows — the tabs
    # must wrap, not scroll, for the classic multi-row look.
    ctx.window("egui.cr Properties", Egui::Pos2.new(70.0, 70.0),
      width: 430.0) do |ui|
      ui.tabs(TABS, @tab, layout: @layout) { |t| @tab = t }

      # Per-tab property rows on an aligned Grid (a distinct grid id
      # per tab so each keeps its own measured column widths).
      ui.grid("props_#{@tab}") do |grid|
        rows(TABS[@tab]).each do |key, value|
          grid.label(key)
          grid.label(value)
          grid.end_row
        end
      end

      ui.separator
      ui.checkbox(@layout == :carousel,
        "carousel (single scrolling row)") do |checked|
        @layout = checked ? :carousel : :multiline
      end

      # The classic property-sheet button row.
      ui.horizontal do |h|
        if h.button("OK").clicked? || h.button("Cancel").clicked?
          Egui::SystemPorts::Quit.quit!
        end
        if h.button("Apply").clicked?
          @applied = "applied: #{TABS[@tab]}"
        end
        h.label(@applied)
      end
    end
  end

  private def rows(tab : String) : Array(Tuple(String, String))
    if (props = PROPS[tab]?)
      props.to_a
    else
      [{"Tab", tab}, {"Content", "(no properties — a demo filler row)"}]
    end
  end
end

Egui.run(WinPropertiesDemo.new,
  title: "egui-cr — Windows Properties tabs (Win95)", inspector: :hidden)
