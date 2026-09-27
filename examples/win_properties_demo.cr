# Windows-Properties-style tab strip: `layout: :multiline` on the Tabs
# widget wraps full rows — one line of tabs fills up, the next starts
# below it (a baseline per row, like a Win32 property sheet). Every tab
# stays visible and clickable; the strip grows downward and pushes the
# dialog content along. Toggle the checkbox to compare with the
# default `:carousel` (one scrolling row that keeps the active tab in
# view) on the same tab set.

require "../src/egui"
require "../src/egui/backend/sokol"

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
      "Owner"    => "oleg",
      "Group"    => "oleg",
      "Mode"     => "rw-r--r--",
    },
    "Details"  => {
      "Origin"   => "egui.cr (local)",
      "Tabs"     => "#{TABS.size} (wrapped into several rows)",
      "Layout"   => ":multiline (Windows Properties style)",
    },
  }

  @tab = 0
  @layout = :multiline
  @applied = "not applied yet"

  def update(ctx : Egui::Context) : Nil
    # Real properties dialogs are small, fixed-ish windows — the tabs
    # must wrap, not scroll, for the classic multi-row look.
    ctx.window("egui.cr Properties", Egui::Pos2.new(60.0, 60.0),
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

Egui::Backend::Sokol.run(WinPropertiesDemo.new,
  title: "egui-cr — Windows Properties tabs")
