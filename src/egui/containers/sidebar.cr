# egui.cr-native navigation container (no direct upstream counterpart):
# a sidebar of titled sections, each holding tabs. Selection follows the
# Checkbox pattern — the app owns it, passes the current section/tab in,
# and reads the new selection back through the `Ui#sidebar` block when
# it changed this frame.

module Egui
  class Sidebar
    include Widget

    # A titled group of tabs.
    class Section
      getter title : String
      getter tabs : Array(String)

      def initialize(@title : String, @tabs : Array(String))
      end
    end

    getter selected_section : Int32
    getter selected_tab : Int32

    def initialize(@sections : Array(Section),
                   @selected_section : Int32 = 0,
                   @selected_tab : Int32 = 0)
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
      style = ui.style
      visuals = style.visuals
      font_size = style.font_size
      response : Response? = nil

      @sections.each_with_index do |section, si|
        # Section title: small, faded, uppercase — not clickable, the
        # tabs below it do the navigation.
        title_size = font_size * 0.8
        rect = ui.allocate_at_least(
          Vec2.new(ui.available_width, title_size * Fonts::LINE_H_FACTOR))
        ui.painter.text(rect.left_center, section.title.upcase, title_size,
          visuals.fade_color(visuals.text_color))

        section.tabs.each_with_index do |tab, ti|
          selected = si == @selected_section && ti == @selected_tab
          size = Vec2.new(ui.available_width, style.spacing.interact_size.y)
          rect = ui.allocate_at_least(size)
          id = ui.next_widget_id
          tab_resp = ui.interact(rect, id, Sense.click)

          # Selected tab gets the accent fill, hover the weak one —
          # selection stays distinguishable from hover.
          if selected
            ui.painter.rect(rect, 3.0, visuals.selection_fill)
          elsif tab_resp.hovered?
            ui.painter.rect(rect, 3.0, visuals.button_weak)
          end
          ui.painter.text(
            Pos2.new(rect.min.x + style.spacing.button_padding.x,
              rect.center.y),
            tab, font_size, visuals.text_color)

          response ||= tab_resp
          if tab_resp.clicked? && !selected
            @selected_section = si
            @selected_tab = ti
            tab_resp.mark_changed
            response = tab_resp
            ui.ctx.request_repaint
          end
        end

        ui.separator unless si == @sections.size - 1
      end

      response.not_nil!
    end
  end

  class Ui
    # `ui.sidebar(sections, section, tab) { |s, t| … }` — shows a Sidebar
    # and hands back the new selection when it changed this frame.
    def sidebar(sections : Array(Sidebar::Section), selected_section : Int32,
                selected_tab : Int32, &on_select : Int32, Int32 ->) : Response
      widget = Sidebar.new(sections, selected_section, selected_tab)
      response = add(widget)
      if response.changed?
        on_select.call(widget.selected_section, widget.selected_tab)
      end
      response
    end
  end
end
