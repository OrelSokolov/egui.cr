# Class-based context menus: an `Egui::ContextMenu` is a reusable menu
# definition — rows with an optional vector icon and a hotkey hint
# (either a live `HotkeyAction` binding from `ctx.hotkeys` or a static
# string), plus separators. Attach it to any widget through its
# Response: a secondary-button press over the widget opens the menu at
# the pointer, built on the same popup system as `Ui#menu_button`.
#
#   menu = Egui::ContextMenu.new
#     .item("Copy", icon: :copy, hotkey: "Ctrl+C") { copy }
#     .separator
#     .item("Delete", icon: :trash) { delete }
#   ui.textarea(buf) { |t| buf = t }.context_menu(menu)
#
# The same menu instance may drive several widgets (each attachment
# opens its own popup, keyed by the widget's id).

module Egui
  # egui `Response::context_menu` for a prebuilt `ContextMenu` — the
  # class-based twin of the block version in containers/menu.cr.
  class Response
    def context_menu(menu : ContextMenu) : self
      context_menu { |menu_ui| menu.render(menu_ui) }
      self
    end
  end

  class ContextMenu
    # One clickable row. `action`, when set, both supplies the live
    # shortcut hint (whatever `ctx.hotkeys` binds right now) and makes
    # the row trigger on the hotkey while the menu is open; `hotkey`
    # is a static hint for rows without an action.
    class Item
      getter label : String
      getter icon : Symbol?
      getter action : HotkeyAction?
      getter hotkey : String?
      getter handler : (->)?

      def initialize(@label : String, @icon : Symbol?, @action : HotkeyAction?,
                     @hotkey : String?, @handler : (->)?)
      end
    end

    @items = [] of Item | Separator

    def initialize
    end

    # A row with a click handler.
    def item(label : String, icon : Symbol? = nil,
             action : HotkeyAction? = nil, hotkey : String? = nil,
             &on_click : ->) : self
      @items << Item.new(label, icon, action, hotkey, on_click)
      self
    end

    # A row without a handler: clicking it re-fires `action` (if any)
    # for app-level `Context#consume_action` handlers, then closes.
    def item(label : String, icon : Symbol? = nil,
             action : HotkeyAction? = nil, hotkey : String? = nil) : self
      @items << Item.new(label, icon, action, hotkey, nil)
      self
    end

    # A horizontal rule between rows.
    def separator : self
      @items << Separator.new
      self
    end

    # Draw the rows into the open popup's Ui (called from
    # `Response#context_menu`; rows close the popup via the shared
    # `menu_popup_key` machinery).
    def render(ui : Ui) : Nil
      @items.each do |entry|
        case entry
        in Separator
          ui.separator
        in Item
          ui.menu_item(entry.label, entry.action, entry.icon,
            entry.hotkey) do
            if (handler = entry.handler)
              handler.call
            elsif (action = entry.action)
              ui.ctx.fire_action(action)
            end
          end
        end
      end
    end

    struct Separator
    end
  end
end
