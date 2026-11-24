# System tray demo — the SystemPorts::Tray port on every platform
# where a backend wires it (macOS: NSStatusItem; Windows:
# Shell_NotifyIconW; Linux: opt-in `require "egui/driver/tray_linux"`).
#
# The tray icon is created from update (the GUI thread); every click
# on the icon opens the menu, and item activations arrive between
# frames through take_clicks (on Windows the menu runs on the tray's
# own message-loop thread — same shape as the Linux GTK thread).
#
# Items to try: plain, checkable (model toggles, menu shows the new
# state on the next open), a separator, a submenu (parent added
# BEFORE its children), a dynamically re-titled item and Quit.

require "../src/egui/driver_selector"

# Linux's tray surface is opt-in (macOS/Windows are wired by sokol).
{% if flag?(:linux) && !flag?(:android) %}
  require "../src/egui/driver/tray_linux"
{% end %}

class TrayApp < Egui::App
  ID_SHOW    = 1
  ID_TOGGLE  = 2
  ID_SEP     = 3
  ID_SUBMENU = 10
  ID_SUB_A   = 11
  ID_SUB_B   = 12
  ID_RENAME  = 20
  ID_QUIT    = 30

  @created = false
  @last = "пока пусто"
  @toggled = true
  @rename_count = 0

  def update(ctx : Egui::Context) : Nil
    unless @created
      @created = true
      tray = Egui::SystemPorts::Tray
      if tray.supported?
        bytes = File.read("#{__DIR__}/../assets/icon.png").to_slice
        tray.create(Egui::SystemPorts::Tray::IconSource.png(bytes),
          tooltip: "egui-cr tray demo")
        tray.add_item(ID_SHOW, "Показать счётчик кликов")
        tray.add_item(ID_TOGGLE, "Тумблер", checkable: true, checked: @toggled)
        tray.add_separator(ID_SEP)
        tray.add_item(ID_SUBMENU, "Подменю →")
        tray.add_item(ID_SUB_A, "Внутри A", parent_id: ID_SUBMENU)
        tray.add_item(ID_SUB_B, "Внутри B", parent_id: ID_SUBMENU)
        tray.add_item(ID_RENAME, "Переименуй меня")
        tray.add_separator(ID_SEP + 1)
        tray.add_item(ID_QUIT, "Выход")
      end
    end

    # Drain menu activations (they fire between frames, possibly on
    # the tray thread — the queue is mutex-guarded).
    Egui::SystemPorts::Tray.take_clicks.each do |id|
      case id
      when ID_SHOW    then @last = "клик: показать (#{@rename_count})"
      when ID_TOGGLE  then @toggled = !@toggled
      when ID_SUB_A   then @last = "клик: подменю A"
      when ID_SUB_B   then @last = "клик: подменю B"
      when ID_RENAME
        @rename_count += 1
        @last = "клик: переименован (#{@rename_count})"
        # Mutating the model re-renders the menu on its next open.
        Egui::SystemPorts::Tray.add_item(ID_RENAME,
          "Переименуй меня ×#{@rename_count}")
      when ID_QUIT    then Egui::SystemPorts::Quit.quit!
      end
    end

    ctx.window("Tray", Egui::Pos2.new(40.0, 40.0), width: 420.0) do |ui|
      if Egui::SystemPorts::Tray.supported?
        ui.heading("Системный трей")
        ui.label("иконка в трее — клик открывает меню")
        ui.separator
        ui.label("последнее действие: #{@last}")
        ui.label("тумблер из меню: #{@toggled ? "вкл" : "выкл"}")
      else
        ui.heading("Трей не поддержан на этой платформе")
        ui.label("(headless/no-op порт: supported? = false)")
      end
    end
  end
end

Egui.run(TrayApp.new, title: "egui-cr — tray", inspector: :hidden)
