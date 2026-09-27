# egui.cr-native tab strip (no direct upstream counterpart): a
# horizontal row of tabs meant to sit at the top of a tab container.
# Selection follows the same Checkbox pattern as the Sidebar — the app
# owns it, passes the current tab in, and reads the new selection back
# through the `Ui#tabs` block when it changed this frame. `closable:`
# arms a nested close button (X) in every tab — same hit-testing trick
# as the sidebar: the nested widget interacts after the tab, so the
# click routes to the X and the app gets `on_close`.
#
# The active tab is highlighted with a background fill plus an
# underline along its bottom edge (`fill`, `underline_color` /
# `underline_width` of the `:selected` overlay), drawn on top of the
# full-width baseline under the strip. When the tabs overflow the
# strip, the strip scrolls carousel-style: the active tab always stays
# fully inside the visible window and off-screen tabs neither paint
# nor interact.
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   tabs          — tab_spacing (gap between tab buttons),
#                   rule_color (the baseline under the strip),
#                   fill (the strip's background; panel_fill by
#                   default — relevant in per-pixel-transparent
#                   windows, where the strip must stay opaque)
#   tabs.tab      — font_size, padding.top/right/…/left, height,
#                   text_color + :hover/:selected overlays
#                   (fill, text_color, underline_color/underline_width)
# The theme presets ship the defaults (`default_theme.cr`);
# every key is introspectable via `ctx.stylesheet.dump`.

module Egui
  class Tabs
    include Widget

    SCROLL_SALT = 0x7A65_u64

    # Element classes for `StyleSheet` tweaks from app code:
    #   ctx.stylesheet.rule(Tabs::TAB_CLASS, …)
    ROOT_CLASS = "tabs"
    TAB_CLASS  = "tabs.tab"

    def style_class : String?
      ROOT_CLASS
    end

    getter selected : Int32
    getter? closable : Bool
    # The tab whose close button was clicked this frame — its index,
    # nil when nothing closed. The app removes the tab from its own
    # state (and fixes the selection).
    getter closed : Int32?

    def initialize(tabs : Array(String), selected : Int32 = 0,
                   @closable : Bool = false)
      @tabs = tabs
      @closed = nil
      @selected = tabs.empty? ? 0 : selected.clamp(0, tabs.size - 1)
    end

    # The selected tab's title.
    def tab_title : String
      @tabs[@selected]
    end

    def ui(ui : Ui) : Response
      # Nothing to navigate — hand back a dead response instead of
      # raising (an app may legitimately close every tab).
      if @tabs.empty?
        rect = ui.allocate_at_least(Vec2.new(ui.available_width, 0.0))
        return ui.interact(rect, ui.next_widget_id, Sense.none)
      end

      ctx = ui.ctx
      sheet = ctx.stylesheet
      style = ui.style
      visuals = style.visuals

      root = sheet.resolve(ROOT_CLASS)
      tab = sheet.resolve(TAB_CLASS)

      tab_gap = root.f64("tab_spacing", 0.0)
      rule_color = root.color("rule_color", visuals.separator_color)
      tab_font = tab.f64("font_size", style.font_size)
      tab_pad = tab.box("padding")

      text_h = ctx.fonts.measure(@tabs.first, tab_font).y
      strip_h = {tab.f64("height", style.spacing.interact_size.y),
                 text_h + tab_pad.vertical}.max

      strip_left = ui.cursor.x
      strip_top = ui.cursor.y
      # Claim the whole strip: unions min_rect across the full width
      # and leaves the cursor BELOW it for the tab container's content.
      strip = ui.allocate_at_least(Vec2.new(ui.available_width, strip_h))

      # Stable id under the strip's first child slot — the carousel
      # offset persists here across frames.
      scroll_id = ui.next_widget_id.child(SCROLL_SALT)
      ctx.memory.use_id(scroll_id)

      # Measure everything first, then lay out: the carousel needs the
      # total width before the first rect is placed.
      icon = text_h * 0.66
      icon_gap = icon * 0.6
      widths = @tabs.map do |title|
        w = ctx.fonts.measure(title, tab_font).x + tab_pad.horizontal
        closable? ? w + icon + icon_gap : w
      end
      total = widths.sum + tab_gap * {@tabs.size - 1, 0}.max
      view_w = strip.width

      # Carousel offset: scroll the strip just enough that the ACTIVE
      # tab stays fully inside the visible window (and clamp to the
      # scrollable range). No overflow → pinned to 0.
      offset = 0.0
      if total > view_w
        offset = ctx.memory.data.get_f64(scroll_id, 0.0)
        sel_start = widths[0...@selected].sum + tab_gap * @selected
        sel_end = sel_start + widths[@selected]
        offset = sel_start if sel_start < offset
        offset = sel_end - view_w if sel_end > offset + view_w
        offset = offset.clamp(0.0, total - view_w)
      end
      ctx.memory.data.set_f64(scroll_id, offset)

      # Strip background (styled "fill" of the `tabs` class, panel_fill
      # by default): painted before everything so the row is opaque even
      # when the container behind it is transparent (a terminal app with
      # a translucent grid — the strip must not show the desktop
      # through the gaps between the tab buttons).
      ui.painter.rect(strip, fill: root.color("fill", visuals.panel_fill))

      # Baseline under the strip (the container's top edge) — painted
      # first so tab fills and the selection underline stack on top.
      ui.painter.line(Pos2.new(strip.min.x, strip.max.y),
        Pos2.new(strip.max.x, strip.max.y), 1.0, rule_color)

      response : Response? = nil
      x = strip_left - offset

      # Tabs never paint outside the strip (the strip is the carousel
      # window) — clamp the painter clip while the tabs are drawn. A
      # straddling tab's hit rect is clamped to the window too, so the
      # clipped part cannot catch clicks over neighboring content.
      overflow = total > view_w
      clamp_to_strip = ->(r : Rect) do
        Rect.new(
          Pos2.new({r.min.x, strip.min.x}.max, {r.min.y, strip.min.y}.max),
          Pos2.new({r.max.x, strip.max.x}.min, {r.max.y, strip.max.y}.min))
      end
      outer_clip = ui.painter.clip
      ui.painter.clip = Rect.new(
        Pos2.new({outer_clip.min.x, strip.min.x}.max,
          {outer_clip.min.y, strip.min.y}.max),
        Pos2.new({outer_clip.max.x, strip.max.x}.min,
          {outer_clip.max.y, strip.max.y}.min))

      @tabs.each_with_index do |title, ti|
        selected = ti == @selected
        rect = Rect.from_min_size(Pos2.new(x, strip_top),
          Vec2.new(widths[ti], strip_h))

        # Ids are minted unconditionally so they stay stable regardless
        # of visibility; fully hidden tabs neither paint nor interact
        # (their rects would sit on top of unrelated content).
        id = ui.next_widget_id
        x_id = closable? ? ui.next_widget_id : nil
        hidden = rect.max.x <= strip.min.x || rect.min.x >= strip.max.x

        tab_resp : Response? = nil
        close_resp : Response? = nil
        unless hidden
          hit = overflow ? clamp_to_strip.call(rect) : rect
          tab_resp = ui.interact(hit, id, Sense.click)

          # Nested close button: interacts AFTER the tab so it is the
          # topmost widget under the pointer (hit-testing picks the
          # latest one) — the X eats the click, the tab never fires.
          if x_id
            x_rect = Rect.from_min_size(
              Pos2.new(rect.right - tab_pad.right - icon,
                rect.center.y - icon / 2.0),
              Vec2.new(icon, icon))
            x_rect = clamp_to_strip.call(x_rect) if overflow
            close_resp = ui.interact(x_rect, x_id, Sense.click)
          end
        end
        x_hovered = close_resp.try(&.hovered?) || false

        unless hidden
          # State overlay on top of the base vars: hover the weak fill,
          # selected the accent underline + background (the tab does
          # not count as hovered while the pointer is over its X).
          state_vars = if selected
            sheet.resolve(TAB_CLASS, "selected")
          elsif tab_resp.try(&.hovered?) && !x_hovered
            sheet.resolve(TAB_CLASS, "hover")
          else
            tab
          end
          if (fill = state_vars.color?("fill"))
            ui.painter.rect(rect, 3.0, fill)
          end
          text_color = state_vars.color("text_color", visuals.text_color)
          ui.painter.text(Pos2.new(rect.min.x + tab_pad.left, rect.center.y),
            title, tab_font, text_color)

          # The active tab's bottom border, on top of the baseline.
          if selected
            underline_width = state_vars.f64("underline_width", 2.0)
            underline_color = state_vars.color("underline_color",
              visuals.selection_fill)
            ui.painter.line(Pos2.new(rect.min.x, rect.max.y),
              Pos2.new(rect.max.x, rect.max.y), underline_width,
              underline_color)
          end

          if (cr = close_resp)
            x_color = cr.hovered? ? text_color : visuals.fade_color(text_color)
            if cr.hovered?
              ui.painter.rect(cr.rect, 3.0, visuals.button_hovered)
            end
            Icons.draw(ui.painter, :close, cr.rect, x_color)
          end
        end

        # Flush strip: drop the layout's item_spacing between the
        # buttons, keep only the styled tab_spacing gap.
        x = rect.max.x + tab_gap

        response ||= tab_resp
        if (cr = close_resp) && cr.clicked?
          @closed = ti
          response = cr
          ctx.request_repaint
        elsif (tr = tab_resp) && tr.clicked? && !selected
          @selected = ti
          tr.mark_changed
          response = tr
          ctx.request_repaint
        end
      end

      ui.painter.clip = outer_clip

      response.not_nil!
    end
  end

  class Ui
    # `ui.tabs(titles, selected) { |t| … }` — shows a horizontal Tabs
    # strip and hands back the new selection when it changed this
    # frame. `closable` arms the per-tab close button (an X nested
    # inside the tab — the nested widget interacts after the tab, so
    # hit-testing hands the click to the X, not the tab; a close never
    # selects the tab); `on_close` (optional) fires with the tab index
    # when its X was clicked — the app removes the tab.
    def tabs(titles : Array(String), selected : Int32,
             closable : Bool = false,
             on_close : (Int32 ->)? = nil,
             &on_select : Int32 ->) : Response
      widget = Tabs.new(titles, selected, closable)
      response = add(widget)
      if (closed = widget.closed) && on_close
        on_close.call(closed)
      end
      if response.changed?
        on_select.call(widget.selected)
      end
      response
    end
  end
end
