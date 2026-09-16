# egui.cr-native navigation container (no direct upstream counterpart):
# a sidebar of titled sections, each holding tabs. Selection follows the
# Checkbox pattern — the app owns it, passes the current section/tab in,
# and reads the new selection back through the `Ui#sidebar` block when
# it changed this frame. Sections can be `closable`: each tab row nests
# a close button (X), always shown on the selected tab and elsewhere
# only while its tab is hovered (immediate mode gives the parent's
# hover state the same frame, before the child is drawn — no style
# cascade needed). The nested widget interacts after the tab, so
# hit-testing routes the click to the X and the app gets `on_close`.
#
# When the sections overflow the host panel's height, the contents live
# in a stock vertical ScrollArea (wheel + scrollbar). While scrollable
# the tab rows reserve a BAR_WIDTH gutter so the bar never covers the
# close-X buttons. A selection the app hands in different from last
# frame's (close fix-ups, restores) auto-scrolls into view.
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   sidebar          — tab_spacing (the gap between tab buttons)
#   sidebar.section  — font_size, margin.top/left/…, text_color
#   sidebar.tab      — padding.top/right/bottom/left, height,
#                      text_color + :hover/:selected overlays
#                      (fill, text_color)
# The theme presets ship the defaults (`default_theme.cr`);
# every key is introspectable via `ctx.stylesheet.dump`.

module Egui
  class Sidebar
    include Widget

    # A titled group of tabs. `closable` arms the per-tab close button
    # (an X nested inside the tab row — always rendered on the selected
    # tab, on the others only while hovered; the nested widget
    # interacts after the tab, so hit-testing hands the click to the X,
    # not the tab; a close never selects the tab).
    class Section
      getter title : String
      getter tabs : Array(String)
      getter? closable : Bool

      def initialize(@title : String, @tabs : Array(String),
                     @closable : Bool = false)
      end
    end

    # Element classes for `StyleSheet` tweaks from app code:
    #   ctx.stylesheet.rule(Sidebar::TAB_CLASS, …)
    ROOT_CLASS    = "sidebar"
    SECTION_CLASS = "sidebar.section"
    TAB_CLASS     = "sidebar.tab"

    def style_class : String?
      ROOT_CLASS
    end

    getter selected_section : Int32
    getter selected_tab : Int32
    # The tab whose close button was clicked this frame — `{section,
    # tab}` indices, nil when nothing closed. The app removes the tab
    # from its own state (and fixes the selection).
    getter closed : {Int32, Int32}?

    def initialize(sections : Array(Section), selected_section : Int32 = 0,
                   selected_tab : Int32 = 0)
      @sections = sections
      @closed = nil
      if sections.empty?
        @selected_section = 0
        @selected_tab = 0
      else
        @selected_section = selected_section.clamp(0, sections.size - 1)
        @selected_tab = selected_tab.clamp(
          0, sections[@selected_section].tabs.size - 1)
      end
    end

    # The selected section's title (for headings / dispatch).
    def section_title : String
      @sections[@selected_section].title
    end

    # The selected tab's title.
    def tab_title : String
      @sections[@selected_section].tabs[@selected_tab]
    end

    def ui(ui : Ui) : Response
      # Nothing to navigate — hand back a dead response instead of
      # raising (an app may legitimately close every tab).
      if @sections.empty?
        rect = ui.allocate_at_least(Vec2.new(ui.available_width, 0.0))
        return ui.interact(rect, ui.next_widget_id, Sense.none)
      end

      ctx = ui.ctx
      memory = ctx.memory
      sheet = ctx.stylesheet
      style = ui.style
      visuals = style.visuals

      root = sheet.resolve(ROOT_CLASS)
      sec = sheet.resolve(SECTION_CLASS)
      tab = sheet.resolve(TAB_CLASS)

      tab_gap = root.f64("tab_spacing", 0.0)
      sec_font = sec.f64("font_size", style.font_size * 0.8)
      sec_margin = sec.box("margin")
      sec_color = sec.color("text_color", visuals.fade_color(visuals.text_color))
      tab_font = tab.f64("font_size", style.font_size)
      tab_pad = tab.box("padding")

      # The sections scroll when they overflow the host panel (wheel +
      # scrollbar via the stock ScrollArea). An explicit scroll id lets
      # the sidebar reach the offset/content cells below (auto-scroll
      # to the selection). While scrollable, tab rows reserve a
      # BAR_WIDTH gutter so the bar never covers the close-X buttons.
      # The bar hugs the host panel's right edge (ui.clip) — the panel
      # Ui itself is inset by window_padding, which would otherwise
      # float the bar ~10px inside the edge.
      scroll_id = ui.next_widget_id
      prev_content = memory.data.get_vec2(scroll_id.child(0), Vec2.zero)
      gutter = prev_content.y > ui.available_height ? ScrollArea::BAR_WIDTH : 0.0

      # The incoming selection (what the app passed). Compared against
      # last frame's to detect programmatic changes — those scroll the
      # newly selected tab into view (clicks land inside the viewport
      # already, so for them this is a no-op).
      in_section = @selected_section
      in_tab = @selected_tab
      selected_rect : Rect? = nil
      response : Response? = nil

      viewport = ScrollArea.new(id: scroll_id,
        bar_right: ui.clip.right).show(ui) do |inner|
        @sections.each_with_index do |section, si|
          # Space above each section block (replaces separators).
          inner.cursor = Pos2.new(inner.cursor.x + sec_margin.left,
            inner.cursor.y + sec_margin.top)

          # Section title: small, faded, uppercase — not clickable, the
          # tabs below it do the navigation.
          rect = inner.allocate_at_least(
            Vec2.new(inner.available_width, sec_font * Fonts::LINE_H_FACTOR))
          inner.painter.text(rect.left_center, section.title.upcase, sec_font,
            sec_color)

          section.tabs.each_with_index do |title, ti|
            selected = si == @selected_section && ti == @selected_tab
            text_size = ctx.fonts.measure(title, tab_font)
            # Padding grows the button around its text (CSS box model).
            size = Vec2.new(inner.available_width - gutter,
              {tab.f64("height", style.spacing.interact_size.y),
               text_size.y + tab_pad.vertical}.max)
            rect = inner.allocate_at_least(size)
            id = inner.next_widget_id
            tab_resp = inner.interact(rect, id, Sense.click)

            # Nested close button, live on the selected tab (always — a
            # close affordance must not hide on the tab you are working
            # in) and on any hovered tab; on the rest it is neither
            # painted nor hit-tested in idle. Hover is rect containment
            # on the same layer, so the tab STAYS hovered while the
            # pointer is over its X (which sits inside the tab rect): no
            # flicker when the X appears under the cursor. Interacts
            # AFTER the tab so it is the topmost widget under the pointer
            # (hit-testing picks the latest one) — the X eats the click,
            # the tab never fires.
            close_resp : Response? = nil
            if section.closable? && (selected || tab_resp.hovered?)
              icon = text_size.y * 0.66
              x_rect = Rect.from_min_size(
                Pos2.new(rect.right - tab_pad.right - icon,
                  rect.center.y - icon / 2.0),
                Vec2.new(icon, icon))
              close_resp = inner.interact(x_rect, inner.next_widget_id,
                Sense.click)
            end

            # State overlay on top of the base vars: the selected tab
            # gets the accent fill, hover the weak one (kept over the X
            # too — hovering the close button must not un-hover the tab).
            state_vars = if selected
              sheet.resolve(TAB_CLASS, "selected")
            elsif tab_resp.hovered?
              sheet.resolve(TAB_CLASS, "hover")
            else
              tab
            end
            if (fill = state_vars.color?("fill"))
              inner.painter.rect(rect, 3.0, fill)
            end
            text_color = state_vars.color("text_color", visuals.text_color)
            inner.painter.text(
              Pos2.new(rect.min.x + tab_pad.left,
                rect.min.y + tab_pad.top + text_size.y / 2.0),
              title, tab_font, text_color)

            if (cr = close_resp)
              x_color = cr.hovered? ? text_color : visuals.fade_color(text_color)
              if cr.hovered?
                inner.painter.rect(cr.rect, 3.0, visuals.button_hovered)
              end
              Icons.draw(inner.painter, :close, cr.rect, x_color)
            end

            # Flush tab list: drop the layout's item_spacing between the
            # buttons, keep only the styled tab_spacing gap.
            inner.cursor = Pos2.new(inner.cursor.x, rect.max.y + tab_gap)

            selected_rect = rect if selected
            response ||= tab_resp
            if (cr = close_resp) && cr.clicked?
              @closed = {si, ti}
              response = cr
              ctx.request_repaint
            elsif tab_resp.clicked? && !selected
              @selected_section = si
              @selected_tab = ti
              tab_resp.mark_changed
              response = tab_resp
              ctx.request_repaint
            end
          end
        end
      end

      reveal_selection(ctx, scroll_id, viewport, in_section, in_tab,
        selected_rect)

      response.not_nil!
    end

    # Auto-scroll: when the app hands in a selection different from
    # last frame's (a close fix-up, keyboard navigation, restore), nudge
    # the scroll offset just enough to bring the selected tab back into
    # the viewport. Offset/content cells belong to the inner ScrollArea
    # (id cells 0..2); the sidebar keeps its bookkeeping in 3..4.
    private def reveal_selection(ctx : Context, scroll_id : Id,
                                 viewport : Rect, in_section : Int32,
                                 in_tab : Int32, selected_rect : Rect?) : Nil
      data = ctx.memory.data
      ctx.memory.use_id(scroll_id.child(3))
      ctx.memory.use_id(scroll_id.child(4))
      last_s = data.get_int(scroll_id.child(3), -1)
      last_t = data.get_int(scroll_id.child(4), -1)
      changed = last_s >= 0 && (last_s != in_section || last_t != in_tab)
      data.set_int(scroll_id.child(3), in_section)
      data.set_int(scroll_id.child(4), in_tab)

      return unless changed && (rect = selected_rect)

      offset = data.get_vec2(scroll_id, Vec2.zero).y
      content_h = data.get_vec2(scroll_id.child(0), Vec2.zero).y
      max_offset = {content_h - viewport.height, 0.0}.max
      # Tab rect is in screen coords; content coords sit offset above.
      top = rect.top - viewport.top + offset
      bottom = rect.bottom - viewport.top + offset
      target = offset
      target = {top - 4.0, 0.0}.max if top < offset
      target = {bottom + 4.0 - viewport.height, max_offset}.min \
        if bottom > offset + viewport.height
      target = target.clamp(0.0, max_offset)
      data.set_vec2(scroll_id, Vec2.new(0.0, target)) if target != offset
    end
  end

  class Ui
    # `ui.sidebar(sections, section, tab) { |s, t| … }` — shows a Sidebar
    # and hands back the new selection when it changed this frame.
    # `on_close` (optional) fires with `{section, tab}` indices when a
    # tab's nested close button was clicked — the app removes the tab.
    def sidebar(sections : Array(Sidebar::Section), selected_section : Int32,
                selected_tab : Int32,
                on_close : ((Int32, Int32) ->)? = nil,
                &on_select : Int32, Int32 ->) : Response
      widget = Sidebar.new(sections, selected_section, selected_tab)
      response = add(widget)
      if (closed = widget.closed) && on_close
        on_close.call(closed[0], closed[1])
      end
      if response.changed?
        on_select.call(widget.selected_section, widget.selected_tab)
      end
      response
    end
  end
end
