# egui.cr-native horizontal tab strip (no in-tree upstream counterpart;
# the vertical sibling is `Sidebar`): a row of browser-style tabs.
# Selection follows the Checkbox pattern — the app owns the index,
# passes the current one in, and reads the new selection back through
# the `Ui#tabs` block. The widget itself is stateless, so no IdTypeMap.
#
# The selected tab gets a faded accent fill plus an accent underline;
# hover gets the weak button fill. `closable` arms a nested X per tab
# (the Sidebar pattern: always rendered on the selected tab, elsewhere
# only while hovered; the X interacts after the tab so a close never
# selects).
#
# Styling: plain `Style` values (`effective_style`), no stylesheet
# class yet — adopt `Widget#style_class` here if tabs need theming.

module Egui
  class TabBar
    include Widget

    getter selected : Int32
    # The tab whose close button was clicked this frame — its index,
    # nil when nothing closed. The app removes the tab from its own
    # state (and fixes the selection).
    getter closed : Int32?

    def initialize(@labels : Array(String), selected : Int32 = 0,
                   @closable : Bool = false)
      @selected = @labels.empty? ? 0 : selected.clamp(0, @labels.size - 1)
      @closed = nil
    end

    def ui(ui : Ui) : Response
      # Nothing to navigate — a dead response, like an emptied Sidebar.
      if @labels.empty?
        rect = ui.allocate_at_least(Vec2.new(ui.available_width, 0.0))
        return ui.interact(rect, ui.next_widget_id, Sense.none)
      end

      style = effective_style(ui)
      visuals = style.visuals
      fonts = ui.ctx.fonts
      font_size = style.font_size
      pad = style.spacing.button_padding
      gap = style.spacing.item_spacing.x

      sizes = @labels.map { |l| fonts.measure(l, font_size) }
      height = {sizes.map(&.y).max + pad.y * 2.0,
                 style.spacing.interact_size.y}.max
      icon = sizes.map(&.y).max * 0.66
      # Closable tabs reserve room for the X on their right side.
      cell_widths = sizes.map do |s|
        s.x + pad.x * 2.0 + (@closable ? icon + style.spacing.icon_spacing : 0.0)
      end
      total_w = cell_widths.sum + gap * (@labels.size - 1)

      rect = ui.allocate_at_least(Vec2.new(total_w, height))
      id = ui.next_widget_id

      response : Response? = nil
      x = rect.left
      @labels.each_with_index do |label, i|
        cell = Rect.from_min_size(Pos2.new(x, rect.top),
          Vec2.new(cell_widths[i], height))
        cell_id = id.child(i.to_u64 + 1)
        tab_resp = ui.interact(cell, cell_id, Sense.click)

        # Nested close button (see Sidebar for the interaction-order
        # argument): live on the selected tab and any hovered tab.
        close_resp : Response? = nil
        if @closable && (i == @selected || tab_resp.hovered?)
          x_rect = Rect.from_min_size(
            Pos2.new(cell.right - pad.x - icon,
              cell.center.y - icon / 2.0),
            Vec2.new(icon, icon))
          close_resp = ui.interact(x_rect, id.child(i.to_u64 + 1).child(0),
            Sense.click)
        end

        selected = i == @selected
        if selected
          ui.painter.rect(cell, 4.0,
            visuals.fade_color(visuals.selection_fill, 0.30))
          ui.painter.line(
            Pos2.new(cell.left + 2.0, cell.bottom - 1.5),
            Pos2.new(cell.right - 2.0, cell.bottom - 1.5),
            3.0, visuals.selection_fill)
        elsif tab_resp.hovered?
          ui.painter.rect(cell, 4.0, visuals.button_hovered)
        end

        text_color = selected ? visuals.title_color : visuals.text_color
        ui.painter.text(
          Pos2.new(cell.left + pad.x, cell.center.y),
          label, font_size, text_color)

        if (cr = close_resp)
          x_color = cr.hovered? ? text_color : visuals.fade_color(text_color)
          if cr.hovered?
            ui.painter.rect(cr.rect, 3.0, visuals.button_hovered)
          end
          Icons.draw(ui.painter, :close, cr.rect, x_color)
        end

        response ||= tab_resp
        if (cr = close_resp) && cr.clicked?
          @closed = i
          response = cr
          ui.ctx.request_repaint
        elsif tab_resp.clicked? && !selected
          @selected = i
          tab_resp.widget_value = i.to_f64
          tab_resp.mark_changed
          response = tab_resp
          ui.ctx.request_repaint
        end

        x += cell_widths[i] + gap
      end

      response.not_nil!
    end
  end

  class Ui
    # `ui.tabs(labels, selected) { |i| … }` — shows a TabBar and hands
    # back the newly selected index when it changed this frame.
    # `closable` arms per-tab X buttons; `on_close` (optional) fires
    # with the closed tab's index — the app removes the tab.
    def tabs(labels : Array(String), selected : Int32,
             closable : Bool = false,
             on_close : (Int32 ->)? = nil,
             &on_select : Int32 ->) : Response
      widget = TabBar.new(labels, selected, closable)
      response = add(widget)
      if (closed = widget.closed) && on_close
        on_close.call(closed)
      end
      if response.changed? && (v = response.widget_value)
        on_select.call(v.to_i)
      end
      response
    end
  end
end
