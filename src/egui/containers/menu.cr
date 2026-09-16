# Port of egui_upstream/crates/egui/src/containers/menu.rs.
#
# A desktop-style menu: `Context#menu_bar` pins a bar to the top of the
# window; `Ui#menu_button` opens a dropdown (the shared popup system)
# below itself; `Ui#menu_item` is a clickable row with an optional
# shortcut hint that closes the menu on click. While any menu is open,
# hovering another root button switches to it (upstream MenuState).

module Egui
  # Context menus (egui `Response::context_menu`, containers/menu.rs):
  # a secondary-button press over the widget opens a popup menu at the
  # pointer; built on the same popup system as `Ui#menu_button`, so
  # `menu_item` rows close it and a click elsewhere dismisses it.
  class Response
    def context_menu(&block : Ui ->) : self
      menu_id = "context_menu_#{@id.value}"

      # Open on secondary press (upstream opens on click; press feels
      # snappier and needs no per-button click classification). Checks
      # pointer-in-rect rather than `hovered?` so it works on widgets
      # without hover sense (labels). The anchor rides `Areas` —
      # unpruned per-frame state — so the popup stays where it was
      # opened, not where the pointer wanders.
      pop_id = Id.from("popup/#{menu_id}")
      if @ctx.input.secondary_pressed? &&
         (pos = @ctx.input.secondary_pos) && @rect.contains?(pos)
        @ctx.memory.areas.set_pos(pop_id, pos)
        @ctx.open_popup(menu_id)
      end

      if @ctx.popup_open?(menu_id)
        anchor = @ctx.memory.areas.pos_for(pop_id, @rect.min)
        @ctx.popup(menu_id, anchor) do |menu_ui|
          menu_ui.menu_popup_key = menu_id
          yield menu_ui
        end
      end

      self
    end
  end

  # Vertical padding inside menu rows — dropdown items and bar buttons
  # alike. Roomier than `button_padding.y` so rows breathe like a
  # native menu.
  MENU_PAD_Y = 6.0

  class Context
    # egui `MenuBar::ui` — a native-looking strip pinned to the top of
    # the screen. Like `#top_panel`, it claims its strip out of
    # #available_rect so later panels start below the bar instead of
    # painting over it. The strip is exactly one menu row tall and the
    # buttons fill its full height — no padding between the buttons
    # and the bar. `bar.menu_button("File") { |ui| … }` fills it.
    def menu_bar(&block : Ui ->) : Nil
      avail = @available_rect
      pad = style.spacing.window_padding
      # Bar height is text-driven (menus are not buttons — the
      # interact_size floor grew with the GTK-proportioned button
      # defaults and must not stretch menu rows).
      line_h = style.font_size * Fonts::LINE_H_FACTOR
      height = line_h + 2 * MENU_PAD_Y

      outer = Rect.from_min_size(avail.min, Vec2.new(avail.width, height))
      @available_rect = Rect.new(Pos2.new(outer.left, outer.bottom),
        @available_rect.max)

      @painter.layer = Order::Background
      bg_index = @painter.add_noop
      @painter.clip = outer
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 0.0, style.visuals.panel_fill,
          style.visuals.window_stroke, 1.0))

      ui = Ui.new(self, Id.from("menu_bar"),
        Rect.from_min_size(Pos2.new(outer.min.x + pad.x, outer.min.y),
          Vec2.new(outer.width - 2 * pad.x, height)),
        Layout.left_to_right)
      yield ui

      @painter.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))

      # Keep the hover-switch machinery ticking while a menu is open.
      request_repaint unless @memory.menu_open.nil?
    end
  end

  class Ui
    # egui `MenuButton` — a root menu entry. Click to open; hover to
    # switch when another menu is already open. The button fills the
    # menu bar's full height so its highlight runs edge-to-edge with
    # the strip, like a native bar entry.
    def menu_button(label : String, &block : Ui ->) : Nil
      font_size = style.font_size
      pad = style.spacing.button_padding
      text_size = ctx.fonts.measure(label, font_size)

      rect = allocate_at_least(Vec2.new(text_size.x + 2 * pad.x,
        {available_height, text_size.y}.max))
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
      painter.text(rect.left_center + Vec2.new(pad.x, 0.0),
        label, font_size, visuals.text_color)

      if mine_open
        # Zero vertical pad: the frame starts right at the first item
        # and ends right after the last one (the rows already poke out
        # horizontally to cover the side padding).
        pad_x = ctx.style.spacing.window_padding.x
        # The button rect anchors the dropdown: near the screen bottom
        # it flips open above the bar (Context#popup).
        ctx.popup(popup_key, rect,
          width: 180.0, pad: Vec2.new(pad_x, 0.0)) do |menu_ui|
          menu_ui.menu_popup_key = popup_key
          yield menu_ui
        end
      end
    end

    # The popup this menu content lives in (set by #menu_button so
    # #menu_item can close it).
    property menu_popup_key : String?

    # egui menu item — a row that closes its menu on click. The row
    # spans the popup frame edge-to-edge so the hover highlight covers
    # the whole menu width like a native one; the label sits left with
    # button padding, the shortcut hint is right-aligned. Only the
    # natural width (label + gap + shortcut + padding) is reported to
    # the popup's min_rect, so the frame hugs the widest item.
    def menu_item(label : String, shortcut : String? = nil,
                  &on_click : ->) : Nil
      font_size = style.font_size
      pad = style.spacing.button_padding
      label_size = ctx.fonts.measure(label, font_size)

      shortcut_size = shortcut ? ctx.fonts.measure(shortcut, font_size) : Vec2.zero
      # Row height includes the menu vertical padding so the hover
      # highlight breathes around the label like a native menu row.
      # Text-driven like the bar (see menu_bar): no interact_size
      # floor — menus did not grow with the button defaults.
      height = label_size.y + 2 * MENU_PAD_Y
      shortcut_gap = shortcut ? 24.0 : 0.0
      natural_w = 2 * pad.x + label_size.x + shortcut_gap + shortcut_size.x
      row_w = {available_width, natural_w}.max

      # Full-bleed row: the popup Ui is inset by window_padding, so the
      # row pokes back out on both sides — the hover highlight and the
      # click area cover the menu frame edge-to-edge, like a native menu.
      wpad = style.spacing.window_padding.x
      id = next_widget_id
      rect = Rect.from_min_size(Pos2.new(@cursor.x - wpad, @cursor.y),
        Vec2.new(row_w + 2 * wpad, height))
      @min_rect = @min_rect.union(
        Rect.from_min_size(@cursor, Vec2.new(natural_w, height)))
      # Rows stack flush: no item_spacing gap between menu items, so
      # the hover highlight bands are contiguous like a native menu.
      @cursor = @layout.advance(@cursor, Vec2.new(row_w, height), Vec2.zero)
      response = interact(rect, id, Sense.click)

      visuals = style.visuals
      if response.hovered?
        painter.rect(rect, 3.0, visuals.button_hovered)
      end
      painter.text(rect.left_center + Vec2.new(pad.x, 0.0),
        label, font_size, visuals.text_color)
      if shortcut
        painter.text(Pos2.new(rect.right - pad.x - shortcut_size.x,
          rect.left_center.y), shortcut, font_size, visuals.text_color)
      end

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
