# System tray example: NSStatusItem with a native menu (macOS).
#
# The tray surface is created from `update` (the GUI thread) on the
# first frame; menu clicks are drained through `take_clicks` — the
# immediate-mode consumption style. The window mirrors the tray state:
# clicking "Ping" bumps the counter, the checkable item toggles, the
# submenu item reports which branch fired.

require "../src/egui/backend_selector"

class TrayApp < Egui::App
  ITEM_PING     = 1
  ITEM_CHECK    = 2
  ITEM_SUB_A    = 3
  ITEM_SUB_B    = 4
  SEP_MAIN      = 10
  ITEM_QUIT     = 11

  @created = false
  @checked = false
  @pings = 0
  @last : String? = nil

  def update(ctx : Egui::Context) : Nil
    unless @created
      @created = true
      tray = Egui::SystemPorts::Tray
      if tray.supported?
        icon = begin
          Egui::SystemPorts::Tray::IconSource.png(File.read("assets/icon.png").to_slice)
        rescue
          nil
        end
        tray.create(icon: icon, tooltip: "egui.cr tray")
        tray.add_item(ITEM_PING, "Ping")
        tray.add_item(ITEM_CHECK, "Checkable", checkable: true)
        tray.add_separator(SEP_MAIN)
        # Submenu: parent_id nests the item under that menu item.
        tray.add_item(ITEM_SUB_A, "Submenu A", parent_id: ITEM_PING)
        tray.add_item(ITEM_SUB_B, "Submenu B", parent_id: ITEM_PING)
        tray.add_item(ITEM_QUIT, "Quit")
      end
    end

    # Drain native menu clicks (they queued up between frames).
    Egui::SystemPorts::Tray.take_clicks.each do |id|
      case id
      when ITEM_PING  then @pings += 1; @last = "Ping"
      when ITEM_CHECK then @checked = !@checked; @last = "Checkable = #{@checked}"
      when ITEM_SUB_A then @last = "Submenu A"
      when ITEM_SUB_B then @last = "Submenu B"
      when ITEM_QUIT  then Egui::SystemPorts::Quit.quit!
      end
    end

    ctx.central_panel("demo") do |ui|
      ui.heading("System tray")
      unless Egui::SystemPorts::Tray.supported?
        ui.label("Tray is not supported on this platform/backend.")
        next
      end
      ui.label("The menu lives in the macOS status bar — open it from there.")
      ui.separator
      ui.label("Pings: #{@pings}")
      ui.label("Checkable: #{@checked}")
      ui.label("Last click: #{@last || "—"}")
      ui.separator
      if ui.button("Add one more Ping entry").clicked?
        Egui::SystemPorts::Tray.add_item(ITEM_PING + 100, "Ping ##{@pings + 1}")
      end
      if ui.button("Quit from the window too").clicked?
        Egui::SystemPorts::Quit.quit!
      end
    end
  end
end

Egui.run(TrayApp.new, title: "egui-cr — tray", width: 420, height: 220)
