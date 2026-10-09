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
# full-width baseline under the strip. Two layouts are available:
# `:carousel` (default) keeps every tab on one row — when the tabs
# overflow the strip it scrolls carousel-style, the active tab always
# stays fully inside the visible window and off-screen tabs neither
# paint nor interact; `:multiline` wraps full rows Windows-Properties-
# style — when one line of tabs fills up, the next starts below it
# (a baseline under every row, the strip grows downward).
#
# Styling goes through the global `StyleSheet` (CSS-like classes).
# #ui opens the "tabs" style scope (`Ui#with_style_scope`), so the
# cards chain onto it and any nested real widget styles under
# "tabs.*" automatically:
#   tabs          — tab_spacing (gap between tab buttons),
#                   rule_color (the baseline under the strip),
#                   merge_selected (1.0: the baseline skips the active
#                   tab — Win95-style merging into the page below),
#                   fill (the strip's background; panel_fill by
#                   default — relevant in per-pixel-transparent
#                   windows, where the strip must stay opaque)
#   tabs.tab      — font_size, padding.top/right/…/left, height,
#                   text_color, bevel_light/bevel_dark (raised 3D
#                   border — classic skins) + :hover/:selected
#                   overlays (fill, text_color, bevel_*,
#                   underline_color/underline_width; underline_width
#                   <= 0 disables the underline)
# The theme presets ship the defaults (`default_theme.cr`);
# every key is introspectable via `ctx.stylesheet.dump`.

module Egui
  class Tabs
    include Widget

    SCROLL_SALT = 0x7A65_u64

    # Element classes for `StyleSheet` tweaks from app code:
    #   ctx.stylesheet.rule(Tabs::TAB_CLASS, …)
    # The parts chain onto the "tabs" style scope (`Ui#with_style_scope`
    # in #ui), so the paths derive as "tabs" + part name — the
    # constants below are the resulting paths, kept for app-side rules.
    ROOT_CLASS = "tabs"
    TAB_CLASS  = "tabs.tab"

    def style_class : String?
      ROOT_CLASS
    end

    # The `tabs` root keys #ui reads (the strip itself). The per-card
    # keys of `tabs.tab` are declared by TabPart — the strip records
    # its own meta under the (non-interacting) scroll id so the Class
    # tab knows these props too.
    def style_properties : Array(StyleProp)
      [StyleProp.new("tab_spacing", :number),
       StyleProp.new("rule_color", :color),
       StyleProp.new("background", :color, label: "strip fill"),
       StyleProp.new("merge_selected", :bool, fallback: false)]
    end

    # The StyledPart behind one tab card (see widgets/styled_part.cr):
    # carries the inspector meta for the card's interacts and declares
    # the `tabs.tab` keys. The bare "tab" name chains onto the live
    # "tabs" scope (see #ui). State overlays (:hover/:selected) resolve
    # per card id, so BOTH class rules and per-element inspector edits
    # reach the card.
    class TabPart < StyledPart
      def initialize(label : String)
        super("Tab", "tab", [
          StyleProp.new("height", :number),
          StyleProp.new("font_size", :number),
          StyleProp.new("font_family", :string),
          StyleProp.new("text_color", :color),
          StyleProp.new("padding", :box),
          StyleProp.new("background", :color, states: true),
          StyleProp.new("bevel_light", :color, states: true),
          StyleProp.new("bevel_dark", :color, states: true),
          StyleProp.new("underline_color", :color),
          StyleProp.new("underline_width", :number),
        ], label)
      end
    end

    getter selected : Int32
    getter? closable : Bool
    getter layout : Symbol
    # The tab whose close button was clicked this frame — its index,
    # nil when nothing closed. The app removes the tab from its own
    # state (and fixes the selection).
    getter closed : Int32?

    def initialize(tabs : Array(String), selected : Int32 = 0,
                   @closable : Bool = false, @layout : Symbol = :carousel)
      @tabs = tabs
      @closed = nil
      @selected = tabs.empty? ? 0 : selected.clamp(0, tabs.size - 1)
    end

    # :multiline wraps full rows instead of scrolling one row
    # (`:carousel`) — see the class doc.
    def multiline? : Bool
      @layout == :multiline
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

      # Style scope: the cards below (and any nested real widget)
      # chain onto "tabs.*" — see `Ui#with_style_scope`.
      ui.with_style_scope(ROOT_CLASS) { render(ui) }
    end

    private def render(ui : Ui) : Response
      ctx = ui.ctx
      sheet = ctx.stylesheet
      style = ui.style
      visuals = style.visuals

      root = sheet.resolve(ROOT_CLASS)
      tab = sheet.resolve(TAB_CLASS)

      tab_gap = root.f64("tab_spacing", 0.0)
      rule_color = root.color("rule_color", visuals.separator_color)
      # Win95-style tab merging: the baseline skips the ACTIVE tab's
      # span, so the tab visually connects to the page below it (the
      # strip's own background shows through the gap).
      merge = root.f64("merge_selected", 0.0) > 0.0
      tab_font = tab.f64("font_size", style.font_size)
      # `tabs.tab { font_family }` swaps the strip's font (the rule bag
      # carries the key — same cascade as the size above).
      tab_family = tab.str?("font_family") || style.font_family
      tab_fonts = ctx.fonts_for(tab_family)
      tab_pad = tab.box("padding")

      text_h = tab_fonts.measure(@tabs.first, tab_font).y
      row_h = {tab.f64("height", style.spacing.interact_size.y),
               text_h + tab_pad.vertical}.max

      # Measure everything first, then lay out: the carousel needs the
      # total width and the multiline wrap needs every tab width
      # before the first rect is placed.
      icon = text_h * 0.66
      icon_gap = icon * 0.6
      widths = @tabs.map do |title|
        w = tab_fonts.measure(title, tab_font).x + tab_pad.horizontal
        closable? ? w + icon + icon_gap : w
      end
      total = widths.sum + tab_gap * {@tabs.size - 1, 0}.max
      view_w = ui.available_width

      # Multiline (Windows Properties style): greedily wrap the tabs
      # into rows — one line fills up, the next starts below it. Row
      # origins are collected here (relative to the strip's min
      # corner) so the paint loop below stays layout-agnostic. A tab
      # wider than the whole strip gets a row of its own (clipped to
      # the strip for painting and hit-testing, like a carousel
      # straddler).
      origins = nil.as(Array(Vec2)?)
      row_count = 1
      if multiline?
        origins = [] of Vec2
        ox = 0.0
        oy = 0.0
        widths.each do |w|
          if ox > 0.0 && ox + w > view_w
            ox = 0.0
            oy += row_h
            row_count += 1
          end
          origins << Vec2.new(ox, oy)
          ox += w + tab_gap
        end
      end
      strip_h = row_count * row_h

      strip_left = ui.cursor.x
      strip_top = ui.cursor.y
      # Claim the whole strip: unions min_rect across the full width
      # and leaves the cursor BELOW it for the tab container's content.
      strip = ui.allocate_at_least(Vec2.new(ui.available_width, strip_h))

      # Stable id under the strip's first child slot — the carousel
      # offset persists here across frames.
      scroll_id = ui.next_widget_id.child(SCROLL_SALT)

      # Shadow meta for the ROOT class under the (never-interacting)
      # scroll id: the Class tab learns the `tabs` props, while the
      # card interacts below record TabPart meta (`tabs.tab`) — picking
      # a card addresses the card, the root strip stays reachable
      # through the class combo.
      if ctx.inspector_enabled?
        ctx.inspector.try &.record_meta(scroll_id, self)
      end

      # Carousel offset: scroll the strip just enough that the ACTIVE
      # tab stays fully inside the visible window (and clamp to the
      # scrollable range). No overflow → pinned to 0. Multiline never
      # scrolls (wrapping replaces the offset), so it leaves the
      # persisted value untouched.
      offset = 0.0
      overflow = false
      unless multiline?
        ctx.memory.use_id(scroll_id)
        if total > strip.width
          overflow = true
          offset = ctx.memory.data.get_f64(scroll_id, 0.0)
          sel_start = widths[0...@selected].sum + tab_gap * @selected
          sel_end = sel_start + widths[@selected]
          offset = sel_start if sel_start < offset
          offset = sel_end - strip.width if sel_end > offset + strip.width
          offset = offset.clamp(0.0, total - strip.width)
        end
        ctx.memory.data.set_f64(scroll_id, offset)
      end

      # Strip background (styled "fill" of the `tabs` class, panel_fill
      # by default): painted before everything so the row is opaque even
      # when the container behind it is transparent (a terminal app with
      # a translucent grid — the strip must not show the desktop
      # through the gaps between the tab buttons).
      ui.painter.rect(strip, fill: root.color("background", visuals.panel_fill))

      # The active tab's x-span on its row (for the merge gap) —
      # computed from the layout data, before any rect is painted.
      sel_span = nil.as({Float64, Float64}?)
      sel_row = 0
      if merge
        if (o = origins.try(&.[@selected]?))
          sel_span = {strip.min.x + o.x, strip.min.x + o.x + widths[@selected]}
          sel_row = (o.y / row_h).round.to_i
        else
          sx = strip_left - offset + widths[0...@selected].sum +
               tab_gap * @selected
          sel_span = {sx, sx + widths[@selected]}
        end
      end

      # Baseline(s) under the strip (the container's top edge) —
      # painted first so tab fills and the selection underline stack
      # on top. Multiline draws one per row, like the Win32 property
      # sheet; carousel draws a single full-width line. With
      # `merge_selected` the selected tab's row skips its span.
      paint_rule = ->(y : Float64, row : Int32) do
        if (span = sel_span) && row == sel_row
          a = {span[0], strip.min.x}.max
          b = {span[1], strip.max.x}.min
          if a > strip.min.x + 0.5
            ui.painter.line(Pos2.new(strip.min.x, y),
              Pos2.new(a, y), 1.0, rule_color)
          end
          if b < strip.max.x - 0.5
            ui.painter.line(Pos2.new(b, y),
              Pos2.new(strip.max.x, y), 1.0, rule_color)
          end
        else
          ui.painter.line(Pos2.new(strip.min.x, y),
            Pos2.new(strip.max.x, y), 1.0, rule_color)
        end
      end
      if origins
        row_count.times do |r|
          paint_rule.call(strip.min.y + (r + 1) * row_h, r)
        end
      else
        paint_rule.call(strip.max.y, 0)
      end

      response : Response? = nil
      x = strip_left - offset

      # Tabs never paint outside the strip (the strip is the carousel
      # window) — clamp the painter clip while the tabs are drawn. A
      # straddling tab's hit rect is clamped to the window too, so the
      # clipped part cannot catch clicks over neighboring content.
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
        origin = origins ? strip.min + origins[ti] : Pos2.new(x, strip_top)
        rect = Rect.from_min_size(origin, Vec2.new(widths[ti], row_h))

        # Ids are minted unconditionally so they stay stable regardless
        # of visibility; fully hidden tabs neither paint nor interact
        # (their rects would sit on top of unrelated content).
        id = ui.next_widget_id
        x_id = closable? ? ui.next_widget_id : nil
        hidden = rect.max.x <= strip.min.x || rect.min.x >= strip.max.x

        tab_resp : Response? = nil
        close_resp : Response? = nil
        part = TabPart.new(title)
        unless hidden
          # Clamping is identity for tabs inside the strip; it only
          # bites on carousel straddlers (and a multiline tab wider
          # than the strip itself).
          hit = overflow ? clamp_to_strip.call(rect) : rect
          tab_resp = ctx.with_inspector_widget(part) {
            ui.interact(hit, id, Sense.click) }

          # Nested close button: interacts AFTER the tab so it is the
          # topmost widget under the pointer (hit-testing picks the
          # latest one) — the X eats the click, the tab never fires.
          if x_id
            x_rect = Rect.from_min_size(
              Pos2.new(rect.right - tab_pad.right - icon,
                rect.center.y - icon / 2.0),
              Vec2.new(icon, icon))
            # Clamped for the same reason as the tab's hit rect above.
            x_rect = clamp_to_strip.call(x_rect)
            close_resp = ctx.with_inspector_widget(part) {
              ui.interact(x_rect, x_id, Sense.click) }
          end
        end
        x_hovered = close_resp.try(&.hovered?) || false

        unless hidden
          # State overlay on top of the base vars: hover the weak fill,
          # selected the accent underline + background (the tab does
          # not count as hovered while the pointer is over its X).
          # Resolved per card id — class rules AND per-element
          # inspector overrides both land here.
          state = if selected
            "selected"
          elsif tab_resp.try(&.hovered?) && !x_hovered
            "hover"
          end
          state_vars = part.vars(ui, id, state)
          if (fill = state_vars.color?("background"))
            ui.painter.rect(rect, 3.0, fill)
          end
          # 3D bevel (Win95-style raised tab): light top/left, dark
          # right — the bottom edge is the row baseline (skipped under
          # the active tab by merge_selected, connecting it to the
          # page). Read from the state overlay, so :hover/:selected
          # rules can restyle or drop it.
          if (bl = state_vars.color?("bevel_light")) &&
             (bd = state_vars.color?("bevel_dark"))
            ui.painter.line(rect.min + Vec2.new(0.0, 0.5),
              Pos2.new(rect.max.x, rect.min.y + 0.5), 1.0, bl)
            ui.painter.line(rect.min + Vec2.new(0.5, 0.0),
              Pos2.new(rect.min.x + 0.5, rect.max.y), 1.0, bl)
            ui.painter.line(Pos2.new(rect.max.x - 0.5, rect.min.y),
              Pos2.new(rect.max.x - 0.5, rect.max.y), 1.0, bd)
          end
          text_color = state_vars.color("text_color", visuals.text_color)
          ui.painter.text(Pos2.new(rect.min.x + tab_pad.left, rect.center.y),
            title, tab_font, text_color, family: tab_family)

          # The active tab's bottom border, on top of the baseline —
          # skipped when the overlay sets underline_width to 0 or less
          # (Win95 tabs merge with the page instead).
          if selected
            underline_width = state_vars.f64("underline_width", 2.0)
            if underline_width > 0.0
              underline_color = state_vars.color("underline_color",
                visuals.selection_fill)
              ui.painter.line(Pos2.new(rect.min.x, rect.max.y),
                Pos2.new(rect.max.x, rect.max.y), underline_width,
                underline_color)
            end
          end

          if (cr = close_resp)
            x_color = cr.hovered? ? text_color : visuals.fade_color(text_color)
            # The class `background` paints in the BASE state too (same
            # fix as sidebar's close X); the hovered fill — the :hover
            # overlay or the theme slot — replaces it on top.
            x_vars = part.vars(ui, x_id.not_nil!, cr.hovered? ? "hover" : nil)
            fill = cr.hovered? ?
              x_vars.color?("background") || visuals.button_hovered :
              x_vars.color?("background")
            if fill
              ui.painter.rect(cr.rect, 3.0, fill)
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
    # `ui.tabs(titles, selected) { |t| … }` — shows a Tabs strip and
    # hands back the new selection when it changed this frame.
    # `layout:` picks the overflow behavior: `:carousel` (default) keeps
    # one row that scrolls the active tab into view; `:multiline` wraps
    # full rows Windows-Properties-style. `closable` arms the per-tab
    # close button (an X nested inside the tab — the nested widget
    # interacts after the tab, so hit-testing hands the click to the X,
    # not the tab; a close never selects the tab); `on_close` (optional)
    # fires with the tab index when its X was clicked — the app removes
    # the tab.
    def tabs(titles : Array(String), selected : Int32,
             closable : Bool = false,
             layout : Symbol = :carousel,
             on_close : (Int32 ->)? = nil,
             &on_select : Int32 ->) : Response
      widget = Tabs.new(titles, selected, closable, layout)
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
