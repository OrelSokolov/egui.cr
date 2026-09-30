# Port of egui_upstream/crates/egui/src/containers/menu.rs.
#
# A desktop-style menu: `Context#menu_bar` pins a bar to the top of the
# window; `Ui#menu_button` opens a dropdown (the shared popup system)
# below itself; `Ui#menu_item` is a clickable row with an optional
# vector icon and an optional action whose bound hotkey (ctx.hotkeys)
# shows as the shortcut hint; it closes the menu on click. While any
# menu is open, hovering another root button switches to it (upstream
# MenuState).

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
          # One-menu rule: a widget gets exactly ONE context menu. While
          # the inspector is enabled, its «Inspect …» entry rides along
          # as this menu's LAST item instead of opening a second popup
          # beside it (the class-based ContextMenu twin lands here too —
          # it renders through this block).
          if @ctx.inspector_enabled?
            @ctx.inspector.try &.render_menu_tail(menu_ui, @id)
          end
        end
      end

      self
    end
  end

  # Vertical padding inside menu rows — dropdown items and bar buttons
  # alike. Roomier than `button_padding.y` so rows breathe like a
  # native menu. The default of the `padding` style box of the
  # `menu.item` / `menu.button` classes.
  MENU_PAD_Y = 6.0

  # The StyledPart stand-ins behind menu rows (see widgets/styled_part.cr):
  # menu sites paint in place, so the part carries the inspector meta
  # AND the style keys the row reads. Two classes in the sheet:
  #
  #   menu.item   — a dropdown/popup row: background (hover highlight),
  #                 text_color, font_size, padding (box)
  #   menu.button — a menu-BAR root entry: the same keys, its
  #                 background has :hover AND :active (menu open)
  class MenuItemPart < StyledPart
    def initialize(label : String, class_path : String = "menu.item")
      super("MenuItem", class_path, [
        StyleProp.new("background", :color, states: true),
        StyleProp.new("text_color", :color),
        StyleProp.new("font_size", :number),
        StyleProp.new("padding", :box),
      ], label)
    end
  end

  class MenuButtonPart < StyledPart
    def initialize(label : String)
      super("MenuButton", "menu.button", [
        StyleProp.new("background", :color, states: true),
        StyleProp.new("text_color", :color),
        StyleProp.new("font_size", :number),
        StyleProp.new("padding", :box),
      ], label)
    end
  end

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
      line_h = {style.font_size * Fonts::LINE_H_FACTOR,
        style.spacing.interact_size.y}.max
      height = line_h + 2 * MENU_PAD_Y

      outer = Rect.from_min_size(avail.min, Vec2.new(avail.width, height))
      @available_rect = Rect.new(Pos2.new(outer.left, outer.bottom),
        @available_rect.max)

      @painter.layer = Order::Background
      bg_index = @painter.add_noop
      @painter.clip = outer
      # No stroke: a native menu bar is a plain strip (upstream egui's
      # MenuBar has no frame); the old 1px window_stroke border read as
      # two bright lines around the bar once the caption stopped
      # overlapping its top pixel.
      @painter.set(bg_index,
        RectCmd.new(outer, outer, 0.0, style.visuals.panel_fill,
          nil, 0.0))

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
      part = MenuButtonPart.new(label)
      pad = style.spacing.button_padding
      font_size = style.font_size
      id = next_widget_id
      vars = part.vars(self, id)
      font_size = vars.f64("font_size", font_size)
      unless (box = vars.box?("padding"))
        box = StyleBox.new(MENU_PAD_Y, pad.x, MENU_PAD_Y, pad.x)
      end
      text_size = fonts.measure(label, font_size)

      # In the menu bar the button stretches to the bar's full height
      # so its highlight runs edge-to-edge; nested inside a popup
      # (View → Zoom) the row sizes like a menu_item instead — a popup
      # Ui's max_rect is unbounded, so stretching there would balloon
      # the popup far past its last item.
      height = @menu_popup_key ?
        {text_size.y + 2 * MENU_PAD_Y, style.spacing.interact_size.y}.max :
        {available_height, text_size.y}.max
      rect = allocate_at_least(
        Vec2.new(text_size.x + 2 * box.left, height))
      response = ctx.with_inspector_widget(part) {
        interact(rect, id, Sense.click) }

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
      highlighted = mine_open || response.hovered?
      if highlighted
        # The highlight fill is the state-scoped `background` key: the
        # :active overlay while the menu is open, :hover otherwise, the
        # classic menu-highlight Visuals slots as the user-agent default.
        state_vars = part.vars(self, id, mine_open ? "active" : "hover")
        fill = state_vars.color?("background") ||
               visuals.menu_highlight_fill ||
               (mine_open ? visuals.button_active : visuals.button_hovered)
        painter.rect(rect, 3.0, fill)
      end
      # Text goes highlight-colored only over the band, so a navy
      # highlight can carry white text like a native menu.
      hl_vars = part.vars(self, id, highlighted ? "hover" : nil)
      text_color = highlighted ?
        (hl_vars.color?("text_color") || visuals.menu_highlight_text ||
         visuals.text_color) :
        (vars.color?("text_color") || visuals.text_color)
      painter.text(rect.left_center + Vec2.new(box.left, 0.0),
        label, font_size, text_color, family: style.font_family)

      if mine_open
        # Zero vertical pad: the frame starts right at the first item
        # and ends right after the last one (the rows already poke out
        # horizontally to cover the side padding).
        pad_x = ctx.style.spacing.window_padding.x
        ctx.popup(popup_key, ctx.dropdown_anchor(popup_key, rect),
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
    # button padding (an optional vector icon column before it), the
    # shortcut hint is right-aligned. Only the natural width (icon +
    # label + gap + shortcut + padding) is reported to the popup's
    # min_rect, so the frame hugs the widest item.
    #
    # `action` replaces the old shortcut-string parameter: the hint is
    # whatever hotkey `ctx.hotkeys` currently binds to the action (so
    # a HotkeyEdit rebind updates the menu next frame), and the row
    # triggers on click OR on the action firing while the menu is
    # open. `hotkey` is a static hint for rows without an action.
    # Without a block a click re-fires the action
    # (`Context#fire_action`) for app-level `#consume_action` handlers.
    def menu_item(label : String, action : HotkeyAction? = nil,
                  icon : Symbol? = nil, hotkey : String? = nil,
                  &on_click : ->) : Nil
      menu_item_impl(label, action, icon, hotkey) { on_click.call }
    end

    def menu_item(label : String, action : HotkeyAction? = nil,
                  icon : Symbol? = nil, hotkey : String? = nil) : Nil
      menu_item_impl(label, action, icon, hotkey) do
        ctx.fire_action(action.not_nil!) if action
      end
    end

    private def menu_item_impl(label : String, action : HotkeyAction?,
                               icon : Symbol? = nil, hotkey : String? = nil,
                               &on_trigger : ->) : Nil
      part = MenuItemPart.new(label)
      id = next_widget_id
      vars = part.vars(self, id)
      font_size = vars.f64("font_size", style.font_size)
      pad = style.spacing.button_padding
      unless (box = vars.box?("padding"))
        box = StyleBox.new(MENU_PAD_Y, pad.x, MENU_PAD_Y, pad.x)
      end
      fonts = self.fonts
      label_size = fonts.measure(label, font_size)

      shortcut = action.try { |a| ctx.hotkeys.hotkey_for(a).try(&.to_s) } || hotkey
      shortcut_size = shortcut ? fonts.measure(shortcut.not_nil!, font_size) : Vec2.zero
      # The icon column: a square the label height plus its gap — only
      # for icons the set actually has (unknown names draw nothing and
      # take no space).
      has_icon = !icon.nil? && Icons::NAMES.includes?(icon.not_nil!)
      icon_size = has_icon ? label_size.y + style.spacing.icon_spacing : 0.0
      # Row height includes the menu vertical padding so the hover
      # highlight breathes around the label like a native menu row.
      height = {label_size.y + box.vertical,
        style.spacing.interact_size.y}.max
      shortcut_gap = shortcut ? 24.0 : 0.0
      natural_w = box.horizontal + icon_size + label_size.x +
                  shortcut_gap + shortcut_size.x
      row_w = {available_width, natural_w}.max

      # Full-bleed row: the popup Ui is inset by window_padding, so the
      # row pokes back out on both sides — the hover highlight and the
      # click area cover the menu frame edge-to-edge, like a native menu.
      wpad = style.spacing.window_padding.x
      rect = Rect.from_min_size(Pos2.new(@cursor.x - wpad, @cursor.y),
        Vec2.new(row_w + 2 * wpad, height))
      @min_rect = @min_rect.union(
        Rect.from_min_size(@cursor, Vec2.new(natural_w, height)))
      # Rows stack flush: no item_spacing gap between menu items, so
      # the hover highlight bands are contiguous like a native menu.
      @cursor = @layout.advance(@cursor, Vec2.new(row_w, height), Vec2.zero)
      response = ctx.with_inspector_widget(part) {
        interact(rect, id, Sense.click) }

      visuals = style.visuals
      if response.hovered?
        # The hover band is the state-scoped `background` key of the
        # `menu.item` class — the menu-highlight Visuals slot as the
        # user-agent default.
        hover_vars = part.vars(self, id, "hover")
        fill = hover_vars.color?("background") ||
               visuals.menu_highlight_fill || visuals.button_hovered
        painter.rect(rect, 3.0, fill)
      end
      hl_vars = part.vars(self, id, response.hovered? ? "hover" : nil)
      text_color = response.hovered? ?
        (hl_vars.color?("text_color") || visuals.menu_highlight_text ||
         visuals.text_color) :
        (vars.color?("text_color") || visuals.text_color)
      content_x = rect.left + box.left
      if has_icon
        icon_box = Rect.from_min_size(
          Pos2.new(content_x, rect.center.y - label_size.y / 2.0),
          Vec2.new(label_size.y, label_size.y))
        Icons.draw(painter, icon.not_nil!, icon_box, text_color)
        content_x += icon_size
      end
      painter.text(Pos2.new(content_x, rect.left_center.y),
        label, font_size, text_color, family: style.font_family)
      if shortcut
        painter.text(Pos2.new(rect.right - box.right - shortcut_size.x,
          rect.left_center.y), shortcut, font_size, text_color,
          family: style.font_family)
      end

      # Trigger on click, or on the action firing while this menu is
      # open (a hotkey press — the menu consumes it before the app's
      # poll, so there is exactly one handler either way).
      if response.clicked? || (action && ctx.consume_action(action))
        if key = @menu_popup_key
          ctx.close_popup(key)
          ctx.memory.menu_open = nil
        end
        on_trigger.call
      end
    end
  end
end
