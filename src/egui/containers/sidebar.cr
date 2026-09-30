# egui.cr-native navigation container (no direct upstream counterpart):
# a sidebar of titled sections, each holding tabs. Selection follows the
# Checkbox pattern — the app owns it, passes the current section/tab in,
# and reads the new selection back through the `Ui#sidebar` block when
# it changed this frame. Sections can be `closable`: each tab row nests
# a close button (X) — the nested widget interacts after the tab, so
# hit-testing routes the click to the X and the app gets `on_close`.
# The whole column rides a vertical scroll area, so sections/tabs that
# outgrow the panel scroll (wheel + overlay scrollbar) instead of
# clipping away.
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   sidebar          — tab_spacing (the gap between tab buttons)
#   sidebar.section  — font_size, margin.top/left/…, text_color
#   sidebar.tab      — padding.top/right/bottom/left, height,
#                      text_color + :hover/:selected overlays
#                      (fill, text_color)
#   sidebar.close    — the nested close X buttons: background
#                      (+ :hover overlay), text_color
# The theme presets ship the defaults (`default_theme.cr`);
# every key is introspectable via `ctx.stylesheet.dump`.

module Egui
  class Sidebar
    include Widget

    # A titled group of tabs. `closable` arms the per-tab close button
    # (an X nested inside the tab row — the nested widget interacts
    # after the tab, so hit-testing hands the click to the X, not the
    # tab; a close never selects the tab).
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
    CLOSE_CLASS   = "sidebar.close"

    def style_class : String?
      ROOT_CLASS
    end

    # The StyledPart behind one tab row (see widgets/styled_part.cr):
    # carries the inspector meta for the row's interact and declares
    # the `sidebar.tab` keys. Without it the row's interact recorded
    # the whole Sidebar widget (kind "Sidebar", no stylable props).
    # State overlays (:hover/:selected) resolve per row id, so class
    # rules AND per-element inspector edits both reach the row.
    class TabPart < StyledPart
      def initialize(label : String)
        super("SidebarTab", TAB_CLASS, [
          StyleProp.new("height", :number),
          StyleProp.new("font_size", :number),
          StyleProp.new("font_family", :string),
          StyleProp.new("text_color", :color),
          StyleProp.new("padding", :box),
          StyleProp.new("background", :color, states: true),
        ], label)
      end
    end

    # The StyledPart behind a row's nested close button — its own kind
    # and `sidebar.close` class, so the X is pickable and stylable
    # separately from the tab row it lives in.
    class ClosePart < StyledPart
      def initialize(label : String)
        super("SidebarCloseButton", CLOSE_CLASS, [
          StyleProp.new("background", :color, states: true),
          StyleProp.new("text_color", :color),
        ], label)
      end
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
      # `sidebar.tab { font_family }` swaps the tab strip's font, the
      # section rules theirs (same cascade as the sizes above).
      sec_family = sec.str?("font_family") || style.font_family
      tab_family = tab.str?("font_family") || style.font_family
      sec_fonts = ctx.fonts_for(sec_family)
      tab_fonts = ctx.fonts_for(tab_family)
      tab_pad = tab.box("padding")

      response : Response? = nil

      # The section/tab column sits on a vertical scroll area: when
      # the tabs overflow the panel the wheel + overlay scrollbar take
      # over (instead of the non-fitting tabs silently disappearing off
      # the panel bottom). The bar rides the LEFT side — outside the
      # content, pressed into the panel's left padding, away from the
      # tabs' close X buttons on the right.
      ScrollArea.new(vbar: :left).show(ui) do |inner|
        @sections.each_with_index do |section, si|
          # Space above each section block (replaces separators).
          inner.cursor = Pos2.new(inner.cursor.x + sec_margin.left,
            inner.cursor.y + sec_margin.top)

          # Section title: small, faded, uppercase — not clickable, the
          # tabs below it do the navigation.
          title_h = sec_font * Fonts::LINE_H_FACTOR
          rect = inner.allocate_at_least(
            Vec2.new(inner.available_width, title_h))
          # Overflow guard (moot inside the scroll area's unbounded
          # inner Ui, kept for squashing hosts): a rect that got clamped
          # would poke its centered text half-over the neighbors, so a
          # title that does not fit is not painted at all.
          if rect.height + 0.5 >= title_h
            inner.painter.text(rect.left_center, section.title.upcase, sec_font,
              sec_color, family: sec_family)
          end

          section.tabs.each_with_index do |title, ti|
            selected = si == @selected_section && ti == @selected_tab
            text_size = tab_fonts.measure(title, tab_font)
            # Padding grows the button around its text (CSS box model).
            size = Vec2.new(inner.available_width,
              {tab.f64("height", style.spacing.interact_size.y),
               text_size.y + tab_pad.vertical}.max)
            rect = inner.allocate_at_least(size)
            # Ids are minted unconditionally so they stay stable regardless
            # of visibility (same trick as the Tabs carousel).
            id = inner.next_widget_id
            x_id = section.closable? ? inner.next_widget_id : nil
            part = TabPart.new(title)
            x_part = x_id ? ClosePart.new(title) : nil
            # Overflow guard (moot inside the scroll area's unbounded
            # inner Ui, kept for squashing hosts): a rect that got
            # clamped would poke its text and close X half-over the
            # neighbors (and the X would catch clicks there). Such a
            # tab neither paints nor interacts.
            fits = rect.height + 0.5 >= size.y

            # Nested close button: interacts AFTER the tab so it is the
            # topmost widget under the pointer (hit-testing picks the
            # latest one) — the X eats the click, the tab never fires.
            tab_resp : Response? = nil
            close_resp : Response? = nil
            if fits
              tab_resp = ctx.with_inspector_widget(part) {
                inner.interact(rect, id, Sense.click) }
              if x_id
                icon = text_size.y * 0.66
                x_rect = Rect.from_min_size(
                  Pos2.new(rect.right - tab_pad.right - icon,
                    rect.center.y - icon / 2.0),
                  Vec2.new(icon, icon))
                close_resp = ctx.with_inspector_widget(x_part.not_nil!) {
                  inner.interact(x_rect, x_id, Sense.click) }
              end
            end
            x_hovered = close_resp.try(&.hovered?) || false

            # State overlay on top of the base vars: the selected tab
            # gets the accent fill, hover the weak one (the tab does not
            # count as hovered while the pointer is over its X).
            # Resolved per row id — class rules AND per-element
            # inspector edits both land here.
            if fits
              state = if selected
                "selected"
              elsif tab_resp.try(&.hovered?) && !x_hovered
                "hover"
              end
              state_vars = part.vars(inner, id, state)
              if (fill = state_vars.color?("background"))
                inner.painter.rect(rect, 3.0, fill)
              end
              text_color = state_vars.color("text_color", visuals.text_color)
              inner.painter.text(
                Pos2.new(rect.min.x + tab_pad.left,
                  rect.min.y + tab_pad.top + text_size.y / 2.0),
                title, tab_font, text_color, family: tab_family)

              if (cr = close_resp)
                x_vars = x_part.not_nil!
                  .vars(inner, x_id.not_nil!, cr.hovered? ? "hover" : nil)
                x_color = x_vars.color("text_color",
                  cr.hovered? ? text_color : visuals.fade_color(text_color))
                if cr.hovered?
                  fill = x_vars.color?("background") || visuals.button_hovered
                  inner.painter.rect(cr.rect, 3.0, fill)
                end
                Icons.draw(inner.painter, :close, cr.rect, x_color)
              end
            end

            # Flush tab list: drop the layout's item_spacing between the
            # buttons, keep only the styled tab_spacing gap.
            inner.cursor = Pos2.new(inner.cursor.x, rect.max.y + tab_gap)

            response ||= tab_resp
            if (cr = close_resp) && cr.clicked?
              @closed = {si, ti}
              response = cr
              ctx.request_repaint
            elsif (tr = tab_resp) && tr.clicked? && !selected
              @selected_section = si
              @selected_tab = ti
              tr.mark_changed
              response = tr
              ctx.request_repaint
            end
          end
        end
      end

      # No tab ever interacted (safety net — the scroll area's inner Ui
      # is unbounded, so this is unreachable with non-empty sections;
      # same shape as the empty-sections case above).
      response || begin
        rect = ui.allocate_at_least(Vec2.new(ui.available_width, 0.0))
        ui.interact(rect, ui.next_widget_id, Sense.none)
      end
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
