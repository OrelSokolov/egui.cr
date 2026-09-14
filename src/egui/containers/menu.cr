# Port of egui_upstream/crates/egui/src/containers/menu.rs.
#
# A desktop-style menu: `Context#menu_bar` pins a bar to the top of the
# window; `Ui#menu_button` opens a dropdown (the shared popup system)
# below itself; `Ui#menu_item` is a clickable row with an optional
# shortcut hint that closes the menu on click. While any menu is open,
# hovering another root button switches to it (upstream MenuState).

module Egui
  class Context
    # egui `MenuBar::ui` — a native-looking strip pinned to the top of
    # the screen. `bar.menu_button("File") { |ui| … }` fills it.
    def menu_bar(&block : Ui ->) : Nil
      screen = @input.screen_rect
      pad = style.spacing.window_padding
      line_h = style.font_size * Fonts::LINE_H_FACTOR
      height = line_h + 2 * pad.y

      @painter.layer = Order::Background
      bg_index = @painter.add_noop
      outer = Rect.from_min_size(screen.min, Vec2.new(screen.width, height))
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 0.0, style.visuals.panel_fill,
          style.visuals.window_stroke, 1.0))

      ui = Ui.new(self, Id.from("menu_bar"),
        Rect.from_min_size(screen.min + Vec2.new(pad.x, pad.y),
          Vec2.new(screen.width - 2 * pad.x, line_h)),
        Layout.left_to_right)
      yield ui

      # Keep the hover-switch machinery ticking while a menu is open.
      request_repaint unless @memory.menu_open.nil?
    end
  end

  class Ui
    # egui `MenuButton` — a root menu entry. Click to open; hover to
    # switch when another menu is already open.
    def menu_button(label : String, &block : Ui ->) : Nil
      font_size = style.font_size
      pad = style.spacing.button_padding
      text_size = ctx.fonts.measure(label, font_size)

      rect = allocate_at_least(Vec2.new(text_size.x + 2 * pad.x,
        {text_size.y, style.spacing.interact_size.y}.max))
      id = next_widget_id
      response = interact(rect, id, Sense.click)

      popup_key = "menu_#{id.value}"
      open_menu = ctx.memory.menu_open || ""
      mine_open = open_menu == popup_key

      if response.clicked?
        if mine_open
          ctx.memory.menu_open = nil
          ctx.close_popup(popup_key)
          mine_open = false
        else
          ctx.memory.menu_open = popup_key
          ctx.open_popup(popup_key)
          mine_open = true
        end
      elsif !open_menu.empty? && !mine_open && response.hovered?
        # hover-to-switch while a sibling menu is open
        ctx.close_popup(open_menu) unless open_menu.empty?
        ctx.memory.menu_open = popup_key
        ctx.open_popup(popup_key)
        mine_open = true
      end

      visuals = style.visuals
      if mine_open
        painter.rect(rect, 3.0, visuals.button_active)
      elsif response.hovered?
        painter.rect(rect, 3.0, visuals.button_hovered)
      end
      painter.text(rect.left_center, label, font_size, visuals.text_color)

      if mine_open
        ctx.popup(popup_key, Pos2.new(rect.left, rect.bottom),
          width: 180.0) do |menu_ui|
          menu_ui.menu_popup_key = popup_key
          yield menu_ui
        end
      end
    end

    # The popup this menu content lives in (set by #menu_button so
    # #menu_item can close it).
    property menu_popup_key : String?

    # egui menu item — a row that closes its menu on click.
    def menu_item(label : String, shortcut : String? = nil,
                  &on_click : ->) : Nil
      font_size = style.font_size
      text = shortcut ? "#{label}    #{shortcut}" : label
      text_size = ctx.fonts.measure(text, font_size)

      rect = allocate_at_least(Vec2.new(text_size.x + 2 * style.spacing.button_padding.x,
        {text_size.y, style.spacing.interact_size.y}.max))
      id = next_widget_id
      response = interact(rect, id, Sense.click)

      visuals = style.visuals
      if response.hovered?
        painter.rect(rect, 3.0, visuals.button_hovered)
      end
      painter.text(rect.left_center, text, font_size, visuals.text_color)

      if response.clicked?
        if key = @menu_popup_key
          ctx.close_popup(key)
          ctx.memory.menu_open = nil
        end
        on_click.call
      end
    end
  end
end
