# egui.cr-native widget (no upstream counterpart): a Windows 11
# Notepad-style tab strip that lives IN the window caption, next to
# the caption buttons — draw it through the WindowFrame caption hook:
#
#   Egui::WindowFrame.caption(height: Egui::TitleBarTabs::CAPTION_H) do |ctx, area|
#     Egui::TitleBarTabs.show(ctx, area, titles, selected,
#       dirty: dirty_flags,
#       on_select: ->(t : Int32) { … },   # a tab was clicked
#       on_close: ->(t : Int32) { … },    # a tab's X was clicked
#       on_new: -> { … })                 # the "+" button was clicked
#   end
#
# Look (Win11 Notepad dark): tab cards aligned to the BOTTOM edge of
# the caption (a drag strip of caption air stays above them), the
# active card a notch lighter with rounded top corners, a minimum
# card width so short titles don't squeeze, an X in the active tab
# and on hover (a dot instead while an inactive tab is dirty — the X
# replaces it on hover, exactly Notepad's marker swap), and a "+"
# new-tab button after the last tab. When the tabs overflow the strip
# it scrolls carousel-style — the active tab always stays fully in
# view; off-screen tabs neither paint nor interact.
#
# Layering: the cards ride a Middle layer ABOVE the frame's drag strip
# (z=0), so clicks land on the tabs, never on the window drag — the
# empty caption around the strip still drags/moves the window — and
# BELOW the caption buttons (z=50), which they never overlap anyway.

module Egui
  class TitleBarTabs
    # Caption height while the tabs are installed (Win11 Notepad's
    # tabbed title bar is taller than the plain 32pt caption).
    CAPTION_H    = 44.0  # caption strip height with tabs
    TAB_TOP_GAP  = 8.0   # caption air ABOVE the cards (drag strip)
    ROUNDING     = 8.0   # card top-corner rounding
    PAD_X        = 10.0  # text inset inside a card
    MIN_W        = 110.0 # minimum card width (short titles get air)
    FIRST_INSET  = 8.0   # first card from the strip's left edge
    FONT         = 16.0  # tab text (a notch larger than the caption title)
    ICON         = 11.0  # X / dot box
    ICON_GAP     = 8.0   # air between text and the X
    X_BOX        = 20.0  # X hover-button box (rounded square)
    X_ROUND      = 4.0   # X hover-button corner rounding
    NEW_BOX      = 30.0  # "+" button box
    NEW_GAP      = 8.0   # air between the last tab and "+"

    # Win11 Notepad dark palette: cards sit on the #202020 caption.
    # The ACTIVE card's fill is NOT a constant — it reuses the theme's
    # panel_fill (the menu bar's color), so the active card visually
    # merges with the bar below it, Notepad/Edge-style, in every theme.
    HOVER       = Color32.new(42, 42, 42, 255)    # #2A2A2A inactive hover
    TEXT_ACTIVE = Color32.new(255, 255, 255, 255)
    TEXT_IDLE   = Color32.new(200, 200, 200, 255)
    X_HOVER     = Color32.new(80, 80, 80, 255)    # X hover circle
    NEW_HOVER   = Color32.new(47, 47, 47, 255)    # "+" hover fill

    # Cards above the drag strip (z=0), below the caption buttons
    # (z=50) — see the class doc.
    LAYER = LayerId.new(Order::Middle, Id.from("title_bar_tabs"), 40)

    SCROLL_ID = Id.from("title_bar_tabs/scroll")

    # Show the strip: paints into `area` (the WindowFrame content
    # area) and fires at most one callback this frame. `dirty` marks
    # unsaved tabs (dot instead of X, Notepad's marker).
    def self.show(ctx : Context, area : Rect, titles : Array(String),
                  selected : Int32, dirty : Array(Bool) = [] of Bool,
                  on_select : (Int32 ->)? = nil,
                  on_close : (Int32 ->)? = nil,
                  on_new : (-> Nil)? = nil) : Nil
      painter = ctx.painter
      sel = titles.empty? ? 0 : selected.clamp(0, titles.size - 1)

      # Cards hang from the BOTTOM edge of the caption: the strip air
      # above them (TAB_TOP_GAP) stays a drag region, like Notepad.
      card_top = area.top + TAB_TOP_GAP
      card_h = area.height - TAB_TOP_GAP

      # Measure first, lay out after — the carousel needs the total
      # width before the first rect is placed. The X slot is reserved
      # in EVERY card (active or not) so tabs don't change width when
      # their X appears/disappears on hover — the marker just isn't
      # PAINTED on inactive tabs (see paint_tab).
      widths = titles.map do |title|
        {ctx.fonts.measure(title, FONT).x + 2 * PAD_X + ICON + ICON_GAP,
         MIN_W}.max
      end
      total = widths.sum + NEW_GAP + NEW_BOX

      # Carousel offset (same scheme as Tabs): scroll just enough that
      # the ACTIVE tab stays fully inside the strip. No overflow → 0.
      offset = 0.0
      ctx.memory.use_id(SCROLL_ID)
      if total > area.width
        offset = ctx.memory.data.get_f64(SCROLL_ID, 0.0)
        sel_start = widths[0...sel].sum
        sel_end = sel_start + widths[sel]
        offset = sel_start if sel_start < offset
        offset = sel_end - area.width if sel_end > offset + area.width
        offset = offset.clamp(0.0, {total - area.width, 0.0}.max)
      end
      ctx.memory.data.set_f64(SCROLL_ID, offset)

      x = area.left + FIRST_INSET - offset
      titles.each_with_index do |title, i|
        rect = Rect.from_min_size(Pos2.new(x.round, card_top),
          Vec2.new(widths[i], card_h))
        hidden = rect.max.x <= area.left || rect.min.x >= area.right
        unless hidden
          hit = clamp(rect, area)
          tab_resp = ctx.interact(Id.from("title_bar_tabs/tab/#{i}"),
            hit, Sense.click, LAYER, hit)
          # The X interacts AFTER its tab so hit-testing routes a click
          # over it to the X, never the tab (same trick as Tabs).
          x_rect = Rect.from_min_size(
            Pos2.new(rect.right - PAD_X - ICON,
              rect.center.y - ICON / 2.0),
            Vec2.new(ICON, ICON))
          x_rect = clamp(x_rect, area)
          x_resp = ctx.interact(Id.from("title_bar_tabs/close/#{i}"),
            x_rect, Sense.click, LAYER, x_rect)

          paint_tab(ctx, rect, title, i == sel, tab_resp.hovered?,
            x_resp.hovered?, dirty[i]? || false, area)

          if x_resp.clicked?
            on_close.try(&.call(i))
            ctx.request_repaint
          elsif tab_resp.clicked? && i != sel
            on_select.try(&.call(i))
            ctx.request_repaint
          end
        end
        x = rect.max.x
      end

      # The "+" new-tab button after the last tab (always shown — an
      # empty strip offers the first tab, like Notepad's empty state),
      # pinned to the caption's BOTTOM edge, flush with the cards.
      new_rect = Rect.from_min_size(
        Pos2.new(x.round + NEW_GAP, area.bottom - NEW_BOX),
        Vec2.new(NEW_BOX, NEW_BOX))
      if new_rect.max.x <= area.right
        new_hit = clamp(new_rect, area)
        new_resp = ctx.interact(Id.from("title_bar_tabs/new"),
          new_hit, Sense.click, LAYER, new_hit)

        painter.layer = LAYER.z
        outer_clip = painter.clip
        painter.clip = area
        fill = new_resp.hovered? ? NEW_HOVER : nil
        painter.rect(new_rect, 4.0, fill, nil, 0.0)
        color = new_resp.hovered? ? TEXT_ACTIVE : TEXT_IDLE
        Icons.draw(painter, :plus, new_rect.shrink(9.0), color, 1.5)
        painter.clip = outer_clip

        if new_resp.clicked?
          on_new.try(&.call)
          ctx.request_repaint
        end
      end
    end

    # One tab card: rounded-top fill (a rounded rect squared off along
    # the bottom edge — Painter rounding is all-four-corners) + title
    # + the close marker (X / dirty dot, Notepad's swap).
    private def self.paint_tab(ctx : Context, rect : Rect, title : String,
                               selected : Bool, tab_hovered : Bool,
                               x_hovered : Bool, dirty : Bool,
                               area : Rect) : Nil
      painter = ctx.painter
      painter.layer = LAYER.z
      # The card's own box grown a little (the rounding band), but
      # never past the strip's visible window — carousel straddlers
      # stay cut at the strip edge.
      painter.clip = clip_of(rect.expand(2.0), area)

      fill = selected ? ctx.style.visuals.panel_fill :
        (tab_hovered && !x_hovered ? HOVER : nil)
      if fill
        painter.rect(rect, ROUNDING, fill, nil, 0.0)
        # Square off the card's bottom corners: fill the rounding band.
        painter.rect(Rect.from_min_size(
          Pos2.new(rect.left, rect.bottom - ROUNDING),
          Vec2.new(rect.width, ROUNDING)), 0.0, fill, nil, 0.0)
      end

      text_color = selected || tab_hovered ? TEXT_ACTIVE : TEXT_IDLE
      text_pos = Pos2.new(rect.left + PAD_X, rect.center.y)
      painter.text(text_pos, title, FONT, text_color)

      # Close marker, Notepad rules: the X only in the ACTIVE tab and
      # on hover — an inactive clean tab paints nothing; an inactive
      # dirty tab paints the dot (the X replaces it on hover).
      marker_rect = Rect.from_min_size(
        Pos2.new(rect.right - PAD_X - ICON, rect.center.y - ICON / 2.0),
        Vec2.new(ICON, ICON))
      show_x = selected || tab_hovered || x_hovered
      if !show_x && dirty
        painter.circle_filled(
          Pos2.new(marker_rect.center.x, rect.center.y), 2.5, TEXT_IDLE)
      elsif show_x
        if x_hovered
          # The X as a hover BUTTON: a rounded square behind the glyph
          # (Win11 Notepad's close affordance).
          painter.rect(
            Rect.from_min_size(
              Pos2.new(marker_rect.center.x - X_BOX / 2.0,
                marker_rect.center.y - X_BOX / 2.0),
              Vec2.new(X_BOX, X_BOX)),
            X_ROUND, X_HOVER, nil, 0.0)
        end
        Icons.draw(painter, :close, marker_rect, text_color, 1.5)
      end
    end

    # Clamp a rect into the strip's visible window (carousel/+
    # straddlers must neither paint nor catch clicks outside it).
    private def self.clamp(r : Rect, area : Rect) : Rect
      Rect.new(
        Pos2.new({r.min.x, area.min.x}.max, {r.min.y, area.min.y}.max),
        Pos2.new({r.max.x, area.max.x}.min, {r.max.y, area.max.y}.min))
    end

    # Intersection of two rects as a clip (Nil-safe painter clip needs
    # a real rect; empty intersection is fine — nothing paints).
    private def self.clip_of(a : Rect, b : Rect) : Rect
      min = Pos2.new({a.min.x, b.min.x}.max, {a.min.y, b.min.y}.max)
      max = Pos2.new({a.max.x, b.max.x}.min, {a.max.y, b.max.y}.min)
      Rect.new(min, Pos2.new({min.x, max.x}.max, {min.y, max.y}.max))
    end
  end
end
