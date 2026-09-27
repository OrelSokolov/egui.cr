# egui.cr-native container (no upstream counterpart): a client-side
# window frame drawn after the platform chrome of your choice — the
# default borderless look of `Egui::Backend::Sokol.run(decorations:
# false)` (see the `chrome:`/`chrome_style:` options there).
#
# Four styles (WindowFrame::Style):
#   * Windows — Windows 11: 32pt caption, 46×32 caption buttons, #C42B1C
#     close hover; the dark/light palette follows the app theme
#     (`ctx.theme`), like Win11's own dark/light mode.
#   * WindowsXp — the classic XP Luna look: blue gradient titlebar
#     with glossy rounded caption buttons (red close), app icon slot,
#     and a THICK 6pt blue frame around the client area (the only
#     style that reserves border space — the others share a 1px
#     window outline).
#   * Ubuntu  — the classic Ambiance look (~2017): 28pt titlebar with a
#     vertical warm-grey gradient, centered title, round buttons at the
#     right edge (min, max, close — close in Ubuntu orange #E95420).
#   * Macos   — current macOS: light 28pt titlebar with a separator
#     hairline, centered title, traffic lights at the LEFT edge in
#     Apple order (close, minimize, zoom).
#
# Shared behavior: dragging hands off to the platform's native move
# loop (SystemPorts::Window.start_drag), double-click toggles maximize,
# and invisible 6pt grips along the rim hand resizes to the native
# resize loop.
#
# Caption content hook: `WindowFrame.caption(height:) { |ctx, area| … }`
# draws app content INTO the caption every frame — the Windows 11
# Notepad look, where the tab strip lives in the title bar next to the
# caption buttons (see TitleBarTabs). While content is installed the
# title text is not painted (Notepad shows tabs instead of a title),
# `height:` overrides the caption strip height, and `area` is the
# region the content may claim — the whole bar minus the caption
# buttons (Windows) or the whole bar (other styles). `WindowFrame.caption`
# with no block removes the content and restores the plain caption.

module Egui
  class WindowFrame
    enum Style
      Windows
      WindowsXp
      Ubuntu
      Macos
    end

    EDGE = 6.0 # resize grip thickness (points)

    def self.show(ctx : Context, title : String,
                  style : Style = Style::Windows) : Nil
      frame = case style
              in Style::Windows   then Windows.new(ctx, title)
              in Style::WindowsXp then WindowsXp.new(ctx, title)
              in Style::Ubuntu    then Ubuntu.new(ctx, title)
              in Style::Macos     then Macos.new(ctx, title)
              end
      frame.draw
    end

    # Tracked locally (the ports cannot report the maximize state);
    # toggled by the caption buttons and the double-click. Shared by
    # every style.
    @@maximized = false

    def self.maximized? : Bool
      @@maximized
    end

    def self.toggle_maximize : Nil
      if @@maximized
        SystemPorts::Window.restore
        @@maximized = false
      else
        SystemPorts::Window.maximize
        @@maximized = true
      end
    end

    # --- caption content hook ------------------------------------------------
    #
    # App content drawn into the caption (see the class doc). Content
    # is a class-level proc because the backend calls #show before the
    # app's own update — the app installs it once (e.g. in initialize)
    # and it runs every frame while the chrome is active. Removing the
    # content (no block) also clears the height override: the taller
    # strip exists only while the content does.

    @@caption_content : (Context, Rect ->)? = nil
    @@caption_height : Float64? = nil

    # Install caption content; the optional `height` replaces the style's
    # caption height while the content is installed. `WindowFrame.caption!`
    # removes it and restores the plain caption.
    def self.caption(height : Float64? = nil,
                     &content : Context, Rect ->) : Nil
      @@caption_content = content
      @@caption_height = height
    end

    # Remove caption content (and the height override) — restores the
    # plain caption with its title.
    def self.caption! : Nil
      @@caption_content = nil
      @@caption_height = nil
    end

    # --- app icon slot (Windows style) ----------------------------------------
    #
    # The caption's left edge can carry the app icon (16×16, like the
    # Win11 title bar): `WindowFrame.icon = {rgba:, width:, height:}`
    # — the same tuple `Sokol.run(icon:)` takes, which feeds it here
    # automatically. While installed, the Windows style paints it at
    # the left edge and the title / caption content (tabs) start only
    # AFTER the icon slot. No icon → the layout is unchanged.

    @@icon : NamedTuple(rgba: Bytes, width: Int32, height: Int32)? = nil
    @@icon_texture : UInt64 = 0

    def self.icon=(icon : NamedTuple(rgba: Bytes, width: Int32,
                                     height: Int32)?) : Nil
      @@icon = icon
      @@icon_texture = 0_u64 # force re-registration on next draw
    end

    def self.icon? : NamedTuple(rgba: Bytes, width: Int32, height: Int32)?
      @@icon
    end

    # The icon's texture id, registered lazily (once) on the context.
    def self.icon_texture(ctx : Context) : UInt64
      if (@@icon_texture.zero?) && (icon = @@icon)
        @@icon_texture = ctx.textures.register_rgba(
          icon[:width], icon[:height], icon[:rgba])
      end
      @@icon_texture
    end

    def self.caption_content? : (Context, Rect ->)?
      @@caption_content
    end

    def self.caption_height? : Float64?
      @@caption_height
    end

    getter ctx : Context
    getter title : String

    def initialize(@ctx : Context, @title : String)
    end

    # Draw the frame for this frame. Call BEFORE the app's own panels —
    # the caption is a top panel, so everything the app adds lands
    # below it.
    def draw : Nil
      screen = @ctx.input.screen_rect

      # Grips first: created earlier on the Background layer, panel
      # widgets over the rim win hit-tests against them.
      self.class.resize_grips(@ctx, screen)

      # Caption-content hook reads go through WindowFrame-level
      # accessors — @@vars live per-class in Crystal, and #draw runs
      # on a STYLE SUBCLASS instance whose own copies stay nil.
      h = WindowFrame.caption_height? || caption_height
      bar = @ctx.top_panel("window_frame/caption", height: h) { }
      reserve_border(bar)
      handle_drag(bar)
      paint_caption(bar)
      paint_icon(bar)
      if (content = WindowFrame.caption_content?) && (area = content_area(bar))
        # App caption content (e.g. TitleBarTabs) replaces the title
        # while installed — Win11 Notepad shows tabs, not a title.
        content.call(@ctx, area)
      else
        paint_title(bar)
      end
      paint_buttons(bar)
      paint_border(screen)
    end

    # The caption region app content may claim (#caption hook): the
    # whole bar by default; the Windows style overrides it to exclude
    # the caption buttons.
    def content_area(bar : Rect) : Rect?
      bar
    end

    # The app icon at the caption's left edge (Windows idiom) — see
    # `.icon=`. No-op by default; the Windows styles paint it.
    def paint_icon(bar : Rect) : Nil
    end

    # Reserve non-caption frame space (side/bottom borders) as panels
    # so app content lays out INSIDE the frame. No-op by default; the
    # WindowsXp style reserves its thick blue border here.
    def reserve_border(bar : Rect) : Nil
    end

    # --- style hooks (overridden per style) ---------------------------------

    def caption_height : Float64
      32.0
    end

    # The caption background. Win11 has NO separator under the caption;
    # macOS has one. Fills grow 1pt past the strip and ride z=1 (panels
    # paint at z=0, the deferred central panel later) so no panel
    # stroke can bleed through at the seam.
    def paint_caption(bar : Rect) : Nil
    end

    def paint_title(bar : Rect) : Nil
    end

    # Interact + paint the caption buttons (Middle layer, z=50, so they
    # win hit-tests over the drag strip at z=0).
    def paint_buttons(bar : Rect) : Nil
    end

    # The window outline — shared by every style except WindowsXp
    # (which overrides this with its thick blue border): four
    # pixel-aligned 1px solid bars, painted above every panel (z just
    # under the popup layer) so the central panel's fill cannot cover
    # them. The color follows the app theme (dark / light rim).
    BORDER_DARK  = Color32.new(58, 58, 58, 255)    # 1px outline, dark theme
    BORDER_LIGHT = Color32.new(190, 190, 190, 255) # 1px outline, light theme

    def border_color : Color32
      @ctx.theme.dark? ? BORDER_DARK : BORDER_LIGHT
    end

    def paint_border(screen : Rect) : Nil
      painter.layer = POPUP_LAYER_Z - 1
      painter.clip = screen
      border = border_color
      w = screen.width
      h = screen.height
      painter.rect(Rect.from_min_size(screen.min, Vec2.new(w, 1.0)),
        0.0, border, nil, 0.0)
      painter.rect(Rect.from_min_size(
        Pos2.new(screen.left, screen.bottom - 1.0), Vec2.new(w, 1.0)),
        0.0, border, nil, 0.0)
      painter.rect(Rect.from_min_size(screen.min, Vec2.new(1.0, h)),
        0.0, border, nil, 0.0)
      painter.rect(Rect.from_min_size(
        Pos2.new(screen.right - 1.0, screen.top), Vec2.new(1.0, h)),
        0.0, border, nil, 0.0)
    end

    # --- shared pieces --------------------------------------------------------

    # Drag strip on the Background layer: drag start hands the move to
    # the native window-move loop, double-click toggles maximize — the
    # two things a system title bar does.
    private def handle_drag(bar : Rect) : Nil
      drag = @ctx.interact(Id.from("window_frame/drag"), bar,
        Sense.click_and_drag, LayerId.background, bar)
      if drag.drag_started?
        SystemPorts::Window.start_drag
      end
      if drag.double_clicked?
        WindowFrame.toggle_maximize
      end
    end

    private def painter : Painter
      @ctx.painter
    end

    private def click_action(rect : Rect, name : String) : Response
      resp = @ctx.interact(Id.from("window_frame/btn/#{name}"),
        rect, Sense::Click,
        LayerId.new(Order::Middle, Id.from("window_frame/buttons")), rect)
      case name
      when "minimize" then SystemPorts::Window.minimize if resp.clicked?
      when "maximize" then WindowFrame.toggle_maximize if resp.clicked?
      when "close"    then SystemPorts::Quit.quit! if resp.clicked?
      end
      resp
    end

    # Grips along the window rim: hover/drag set the resize cursor,
    # drag start hands the resize to the native loop (the compositor
    # does the tracking, same rationale as the title-bar drag).
    def self.resize_grips(ctx : Context, screen : Rect) : Nil
      e = EDGE
      grips = {
        {CursorIcon::EwResize,   Rect.from_min_size(screen.min,
                                   Vec2.new(e, screen.height)), :left},
        {CursorIcon::EwResize,   Rect.from_min_size(
                                   Pos2.new(screen.right - e, screen.top),
                                   Vec2.new(e, screen.height)), :right},
        {CursorIcon::NsResize,   Rect.from_min_size(screen.min,
                                   Vec2.new(screen.width, e)), :top},
        {CursorIcon::NsResize,   Rect.from_min_size(
                                   Pos2.new(screen.left, screen.bottom - e),
                                   Vec2.new(screen.width, e)), :bottom},
        {CursorIcon::NwseResize, Rect.from_min_size(
                                   Pos2.new(screen.right - e * 2, screen.bottom - e * 2),
                                   Vec2.new(e * 2, e * 2)), :bottom_right},
        {CursorIcon::NwseResize, Rect.from_min_size(screen.min,
                                   Vec2.new(e * 2, e * 2)), :top_left},
        {CursorIcon::NeswResize, Rect.from_min_size(
                                   Pos2.new(screen.right - e * 2, screen.top),
                                   Vec2.new(e * 2, e * 2)), :top_right},
        {CursorIcon::NeswResize, Rect.from_min_size(
                                   Pos2.new(screen.left, screen.bottom - e * 2),
                                   Vec2.new(e * 2, e * 2)), :bottom_left},
      }

      grips.each_with_index do |(icon, rect, edge), i|
        resp = ctx.interact(Id.from("window_frame/resize/#{i}"),
          rect, Sense::Drag, LayerId.background, rect)
        resp.on_hover_and_drag_cursor(icon)
        if resp.drag_started?
          SystemPorts::Window.start_resize(edge)
        end
      end
    end

    # ==========================================================================
    # Windows 11 (dark & light, follows ctx.theme)
    # ==========================================================================
    class Windows < WindowFrame
      CAPTION_H = 32.0 # Win11 caption height (px @ 100%)
      BTN_W     = 46.0 # caption button width
      GLYPH     = 10.0 # caption glyph box (Segoe Fluent icons, 1px)
      TITLE_PAD = 16.0 # title text inset from the left edge
      TITLE_PT  = 14.0 # caption font
      ICON_SIZE = 16.0 # app icon box (Win11 title bar)
      ICON_PAD  = 10.0 # app icon inset from the left edge
      ICON_GAP  = 8.0  # air between the icon and title/tabs

      # Windows 11 dark palette. The hover/press overlays and the window
      # outline are SOLID colors (6.1%/3.8% white over #202020, what DWM
      # composites) — no alpha blending at draw time, so they render
      # identically on every backend path.
      BG            = Color32.new(32, 32, 32, 255)      # #202020 caption
      FG            = Color32.new(255, 255, 255, 255)   # title + glyphs
      HOVER_FILL    = Color32.new(46, 46, 46, 255)      # 6% white on #202020
      PRESSED_FILL  = Color32.new(40, 40, 40, 255)      # 4% white on #202020
      CLOSE_HOVER   = Color32.new(196, 43, 28, 255)     # #C42B1C
      CLOSE_PRESSED = Color32.new(179, 39, 30, 255)     # #B3271E

      # Windows 11 light palette (same overlays, black on #D6D6D6). The
      # caption sits DARKER than the theme's panel_fill (#F3F3F3) so
      # the tab cards and the menu bar below read against it — the
      # Win11 Notepad light hierarchy: gray titlebar, lighter content.
      BG_LIGHT           = Color32.new(214, 214, 214, 255) # #D6D6D6 caption
      FG_LIGHT           = Color32.new(32, 32, 32, 255)    # #202020 title + glyphs
      HOVER_FILL_LIGHT   = Color32.new(202, 202, 202, 255) # #CACACA hover on #D6D6D6
      PRESSED_FILL_LIGHT = Color32.new(208, 208, 208, 255) # #D0D0D0 press on #D6D6D6
      # The close hover/press red is shared by both palettes; its glyph
      # stays WHITE over the red (what Win11 does in light mode too).
      GLYPH_ON_RED = Color32.new(255, 255, 255, 255)

      # The theme-picked palette: dark or light, following ctx.theme.
      def bg : Color32
        @ctx.theme.dark? ? BG : BG_LIGHT
      end

      def fg : Color32
        @ctx.theme.dark? ? FG : FG_LIGHT
      end

      private def hover_fill : Color32
        @ctx.theme.dark? ? HOVER_FILL : HOVER_FILL_LIGHT
      end

      private def pressed_fill : Color32
        @ctx.theme.dark? ? PRESSED_FILL : PRESSED_FILL_LIGHT
      end

      def caption_height : Float64
        CAPTION_H
      end

      # Caption content (e.g. TitleBarTabs) claims everything LEFT of
      # the three caption buttons — and, with an icon installed, only
      # AFTER the icon slot (tabs follow the icon, Win11 order).
      def content_area(bar : Rect) : Rect?
        left = WindowFrame.icon? ? ICON_PAD + ICON_SIZE + ICON_GAP : 0.0
        Rect.from_min_size(
          Pos2.new(bar.left + left, bar.top),
          Vec2.new({bar.width - left - 3 * BTN_W, 0.0}.max, bar.height))
      end

      # The caption background: #202020 grown 1pt past the strip on
      # the TOP and SIDES (so the window outline seam never bleeds
      # through), but EXACT at the bottom — the old 1pt overshoot
      # covered the menu bar's top pixel with a #202020 line that
      # broke the active-tab/menu-bar merge (they share panel_fill).
      def paint_caption(bar : Rect) : Nil
        painter.layer = 1
        grown = Rect.from_min_size(
          Pos2.new(bar.left - 1.0, bar.top - 1.0),
          Vec2.new(bar.width + 2.0, bar.height + 1.0))
        painter.clip = grown
        painter.rect(grown, 0.0, bg, nil, 0.0)
      end

      def paint_title(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        # With an icon installed the title starts after the icon slot
        # (Win11 order: icon, then title).
        x = bar.left + TITLE_PAD
        x += ICON_PAD + ICON_SIZE + ICON_GAP if WindowFrame.icon?
        painter.text(Pos2.new(x, bar.center.y), title, TITLE_PT, fg)
      end

      # The app icon (see `.icon=`): 16×16 at the left edge, centered
      # against the TAB CARDS (TitleBarTabs geometry: below its top
      # gap) when the caption is tall; in a plain caption — in the
      # whole bar.
      def paint_icon(bar : Rect) : Nil
        return unless WindowFrame.icon?
        texture = WindowFrame.icon_texture(@ctx)
        return if texture.zero?
        top = if bar.height > CAPTION_H
                bar.top + TitleBarTabs::TAB_TOP_GAP +
                  (bar.height - TitleBarTabs::TAB_TOP_GAP - ICON_SIZE) / 2.0
              else
                bar.top + (bar.height - ICON_SIZE) / 2.0
              end
        rect = Rect.from_min_size(
          Pos2.new(bar.left + ICON_PAD, top), Vec2.new(ICON_SIZE, ICON_SIZE))
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        painter.image(rect, texture)
      end

      def paint_buttons(bar : Rect) : Nil
        # Buttons live in the TOP standard strip (CAPTION_H tall,
        # pinned to the top-right corner) — a taller caption (tabs in
        # the title bar) extends the strip BELOW them, exactly like
        # Windows extends the title bar under fixed caption buttons.
        btn_h = CAPTION_H
        close = Rect.from_min_size(
          Pos2.new(bar.right - BTN_W, bar.top), Vec2.new(BTN_W, btn_h))
        max = Rect.from_min_size(
          Pos2.new(close.left - BTN_W, bar.top), Vec2.new(BTN_W, btn_h))
        min = Rect.from_min_size(
          Pos2.new(max.left - BTN_W, bar.top), Vec2.new(BTN_W, btn_h))

        min_resp = button(min, "minimize")
        max_resp = button(max, "maximize")
        close_resp = button(close, "close")

        glyph("minimize", min, fg)
        glyph("maximize", max, fg)
        # The close glyph goes white over the red hover/press fill in
        # BOTH palettes (Win11 keeps it white in light mode too).
        glyph("close", close,
          close_resp.hovered? ? GLYPH_ON_RED : fg)
      end

      # A square caption button: hover/press fill (Win11 overlay colors)
      # + a click Response. The glyph is painted by #glyph.
      private def button(rect : Rect, name : String) : Response
        resp = click_action(rect, name)
        painter.layer = Order::Middle
        painter.clip = rect
        fill = if resp.active? && resp.hovered?
          name == "close" ? CLOSE_PRESSED : pressed_fill
        elsif resp.hovered?
          name == "close" ? CLOSE_HOVER : hover_fill
        end
        painter.rect(rect, 0.0, fill, nil, 0.0)
        resp
      end

      # The Win11 caption glyphs, 10×10 centered, 1px strokes (the Segoe
      # Fluent icon shapes rebuilt from painter primitives).
      private def glyph(name : String, rect : Rect, color : Color32) : Nil
        painter.layer = Order::Middle
        painter.clip = rect
        c = rect.center
        g = GLYPH / 2.0
        case name
        when "minimize"
          # a filled 1px bar (pixel-aligned: a LineCmd would straddle the
          # pixel boundary and render half-strength)
          y = (c.y - 0.5).round
          painter.rect(Rect.from_min_size(
            Pos2.new(c.x - g, y), Vec2.new(GLYPH, 1.0)), 0.0, color, nil, 0.0)
        when "maximize"
          if WindowFrame.maximized?
            # restore: two overlapping square outlines, back sheet offset
            # up-right of the front one
            back = Rect.from_min_size(
              Pos2.new(c.x - g + 3.0, c.y - g - 3.0), Vec2.new(GLYPH, GLYPH))
            painter.rect(back, 1.0, nil, color, 1.0)
            painter.line(Pos2.new(c.x - g, c.y - g + 3.0),
              Pos2.new(c.x - g, c.y + g), 1.0, color)
            painter.line(Pos2.new(c.x - g, c.y + g),
              Pos2.new(c.x + g - 3.0, c.y + g), 1.0, color)
          else
            box = Rect.from_min_size(
              Pos2.new(c.x - g, c.y - g), Vec2.new(GLYPH, GLYPH))
            painter.rect(box, 1.0, nil, color, 1.0)
          end
        when "close"
          painter.line(Pos2.new(c.x - g, c.y - g), Pos2.new(c.x + g, c.y + g),
            1.0, color)
          painter.line(Pos2.new(c.x + g, c.y - g), Pos2.new(c.x - g, c.y + g),
            1.0, color)
        end
      end
    end

    # ==========================================================================
    # Windows XP — the classic Luna theme (~2002): blue gradient
    # titlebar with glossy rounded caption buttons (red close), the app
    # icon slot, and a THICK 6pt blue frame around the client area —
    # the only style that reserves border space (#reserve_border).
    # ==========================================================================
    class WindowsXp < WindowFrame
      CAPTION_H = 28.0 # Luna titlebar height
      BORDER_W  = 4.0  # thick blue frame thickness (XP default, 4px)
      BTN       = 21.0 # glossy caption button box
      BTN_GAP   = 2.0  # gap between buttons
      BTN_INSET = 4.0  # button inset from the right window edge
      TITLE_PAD = 8.0  # title text inset from the left edge
      TITLE_PT  = 12.0 # Tahoma-ish caption font
      ICON_SIZE = 16.0 # app icon box (same slot as the Win11 style)
      ICON_PAD  = 6.0
      ICON_GAP  = 4.0

      # Luna blue titlebar: a bright band at the top fading into the
      # deep blue body (approximated with two stacked gradients).
      CAP_LIGHT     = Color32.new(9, 151, 255, 255)   # #0997FF top band
      CAP_MID       = Color32.new(0, 83, 238, 255)    # #0053EE
      CAP_DEEP      = Color32.new(0, 61, 215, 255)    # #003DD7
      FG            = Color32.new(255, 255, 255, 255) # title + glyphs
      TITLE_SHADOW  = Color32.new(0, 40, 130, 255)    # soft drop shadow

      # The thick frame: solid Luna blue with a navy outer line and a
      # light hairline where it meets the client area.
      FRAME       = Color32.new(0, 85, 234, 255)     # #0055EA
      FRAME_OUTER = Color32.new(8, 49, 217, 255)     # #0831D9
      FRAME_INNER = Color32.new(140, 188, 250, 255)  # #8CBCFA

      # Glossy caption buttons: blue min/max, red close — gradient
      # stops plus a darker ring and hover/press variants.
      BTN_TOP      = Color32.new(94, 158, 245, 255)
      BTN_BOTTOM   = Color32.new(33, 82, 204, 255)
      BTN_RING     = Color32.new(23, 51, 143, 255)
      BTN_HOT_TOP  = Color32.new(130, 185, 255, 255)
      BTN_HOT_BOT  = Color32.new(58, 110, 228, 255)
      BTN_DOWN_TOP = Color32.new(52, 104, 196, 255)
      BTN_DOWN_BOT = Color32.new(18, 52, 158, 255)

      CLOSE_TOP      = Color32.new(245, 130, 92, 255)
      CLOSE_BOTTOM   = Color32.new(202, 44, 10, 255)
      CLOSE_RING     = Color32.new(127, 29, 6, 255)
      CLOSE_HOT_TOP  = Color32.new(255, 160, 120, 255)
      CLOSE_HOT_BOT  = Color32.new(222, 66, 24, 255)
      CLOSE_DOWN_TOP = Color32.new(190, 60, 24, 255)
      CLOSE_DOWN_BOT = Color32.new(150, 26, 6, 255)

      @border_top = 0.0 # where the blue frame starts (caption bottom)

      def caption_height : Float64
        CAPTION_H
      end

      # The thick blue frame: side/bottom panels bite the rim so app
      # content lays out INSIDE the frame — a real XP client area, not
      # content overdrawn by the border.
      def reserve_border(bar : Rect) : Nil
        @border_top = bar.bottom
        @ctx.side_panel(:left, "window_frame/border/left",
          width: BORDER_W) { }
        @ctx.side_panel(:right, "window_frame/border/right",
          width: BORDER_W) { }
        @ctx.bottom_panel("window_frame/border/bottom",
          height: BORDER_W) { }
      end

      def paint_caption(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        grown = bar.shrink(-1.0)
        painter.rect_gradient(grown, 0.0, CAP_MID, CAP_DEEP)
        # the bright Luna band over the upper third of the titlebar
        band_h = {bar.height * 0.35, 2.0}.max
        painter.rect_gradient(Rect.from_min_size(
          Pos2.new(grown.left, grown.top),
          Vec2.new(grown.width, band_h)), 0.0, CAP_LIGHT, CAP_MID)
      end

      def paint_title(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        x = WindowFrame.icon? ? ICON_PAD + ICON_SIZE + ICON_GAP : TITLE_PAD
        pos = Pos2.new(bar.left + x, bar.center.y)
        painter.text(Pos2.new(pos.x + 1.0, pos.y + 1.0), title, TITLE_PT,
          TITLE_SHADOW)
        painter.text(pos, title, TITLE_PT, FG)
      end

      def paint_icon(bar : Rect) : Nil
        return unless WindowFrame.icon?
        texture = WindowFrame.icon_texture(@ctx)
        return if texture.zero?
        rect = Rect.from_min_size(
          Pos2.new(bar.left + ICON_PAD,
            bar.top + (bar.height - ICON_SIZE) / 2.0),
          Vec2.new(ICON_SIZE, ICON_SIZE))
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        painter.image(rect, texture)
      end

      # Caption content (the #caption hook) claims everything left of
      # the caption buttons — and, with an icon installed, only after
      # the icon slot.
      def content_area(bar : Rect) : Rect?
        left = WindowFrame.icon? ? ICON_PAD + ICON_SIZE + ICON_GAP : 0.0
        Rect.from_min_size(
          Pos2.new(bar.left + left, bar.top),
          Vec2.new(
            {bar.width - left - 3 * BTN - 2 * BTN_GAP - BTN_INSET, 0.0}.max,
            bar.height))
      end

      def paint_buttons(bar : Rect) : Nil
        # Buttons pinned to the TOP standard strip — a taller caption
        # (content hook) extends the bar below them.
        y = bar.top + (CAPTION_H - BTN) / 2.0
        close = Rect.from_min_size(
          Pos2.new(bar.right - BTN_INSET - BTN, y), Vec2.new(BTN, BTN))
        max_r = Rect.from_min_size(
          Pos2.new(close.left - BTN_GAP - BTN, y), Vec2.new(BTN, BTN))
        min_r = Rect.from_min_size(
          Pos2.new(max_r.left - BTN_GAP - BTN, y), Vec2.new(BTN, BTN))

        glossy_button(min_r, "minimize",
          {BTN_TOP, BTN_BOTTOM}, {BTN_HOT_TOP, BTN_HOT_BOT},
          {BTN_DOWN_TOP, BTN_DOWN_BOT}, BTN_RING)
        glossy_button(max_r, "maximize",
          {BTN_TOP, BTN_BOTTOM}, {BTN_HOT_TOP, BTN_HOT_BOT},
          {BTN_DOWN_TOP, BTN_DOWN_BOT}, BTN_RING)
        glossy_button(close, "close",
          {CLOSE_TOP, CLOSE_BOTTOM}, {CLOSE_HOT_TOP, CLOSE_HOT_BOT},
          {CLOSE_DOWN_TOP, CLOSE_DOWN_BOT}, CLOSE_RING)
      end

      # A glossy Luna caption button: rounded gradient fill with a
      # darker ring, brighter on hover, deeper on press.
      private def glossy_button(rect : Rect, name : String,
                                fill : {Color32, Color32},
                                hover : {Color32, Color32},
                                down : {Color32, Color32},
                                ring : Color32) : Response
        resp = click_action(rect, name)
        painter.layer = Order::Middle
        painter.clip = rect
        top, bottom = if resp.active? && resp.hovered?
          down
        elsif resp.hovered?
          hover
        else
          fill
        end
        painter.rect(rect, 3.0, top, ring, 1.0, bottom)
        glyph(name, rect, FG)
        resp
      end

      # The Luna glyphs: white, a touch bolder than the Win11 ones.
      private def glyph(name : String, rect : Rect, color : Color32) : Nil
        painter.layer = Order::Middle
        painter.clip = rect
        c = rect.center
        case name
        when "minimize"
          # a 2px bar near the bottom of the button box
          painter.rect(Rect.from_min_size(
            Pos2.new(c.x - 4.5, c.y + 3.0), Vec2.new(9.0, 2.0)),
            0.0, color, nil, 0.0)
        when "maximize"
          if WindowFrame.maximized?
            # restore: two overlapping square outlines, back sheet
            # offset up-right of the front one
            back = Rect.from_min_size(
              Pos2.new(c.x - 3.0, c.y - 6.0), Vec2.new(9.0, 9.0))
            painter.rect(back, 1.0, nil, color, 1.5)
            painter.line(Pos2.new(c.x - 4.5, c.y - 3.0),
              Pos2.new(c.x - 4.5, c.y + 4.5), 1.5, color)
            painter.line(Pos2.new(c.x - 4.5, c.y + 4.5),
              Pos2.new(c.x + 2.0, c.y + 4.5), 1.5, color)
          else
            box = Rect.from_min_size(
              Pos2.new(c.x - 4.5, c.y - 4.5), Vec2.new(9.0, 9.0))
            painter.rect(box, 1.0, nil, color, 1.5)
          end
        when "close"
          painter.line(Pos2.new(c.x - 4.5, c.y - 4.5),
            Pos2.new(c.x + 4.5, c.y + 4.5), 1.5, color)
          painter.line(Pos2.new(c.x + 4.5, c.y - 4.5),
            Pos2.new(c.x - 4.5, c.y + 4.5), 1.5, color)
        end
      end

      # The THICK blue Luna frame (space reserved by #reserve_border):
      # the rim strips filled solid blue, a navy outline around the
      # window and a light hairline where the frame meets the client
      # area.
      def paint_border(screen : Rect) : Nil
        painter.layer = POPUP_LAYER_Z - 1
        painter.clip = screen
        left = Rect.from_min_size(
          Pos2.new(screen.left, @border_top),
          Vec2.new(BORDER_W, screen.bottom - @border_top))
        right = Rect.from_min_size(
          Pos2.new(screen.right - BORDER_W, @border_top),
          Vec2.new(BORDER_W, screen.bottom - @border_top))
        bottom = Rect.from_min_size(
          Pos2.new(screen.left, screen.bottom - BORDER_W),
          Vec2.new(screen.width, BORDER_W))
        painter.rect(left, 0.0, FRAME, nil, 0.0)
        painter.rect(right, 0.0, FRAME, nil, 0.0)
        painter.rect(bottom, 0.0, FRAME, nil, 0.0)

        # navy outline around the window + inner hairline around the
        # client opening (the same four-bar shape as the 1px outline)
        w = screen.width
        h = screen.height
        painter.rect(Rect.from_min_size(screen.min, Vec2.new(w, 1.0)),
          0.0, FRAME_OUTER, nil, 0.0)
        painter.rect(Rect.from_min_size(
          Pos2.new(screen.left, screen.bottom - 1.0), Vec2.new(w, 1.0)),
          0.0, FRAME_OUTER, nil, 0.0)
        painter.rect(Rect.from_min_size(screen.min, Vec2.new(1.0, h)),
          0.0, FRAME_OUTER, nil, 0.0)
        painter.rect(Rect.from_min_size(
          Pos2.new(screen.right - 1.0, screen.top), Vec2.new(1.0, h)),
          0.0, FRAME_OUTER, nil, 0.0)

        client = Rect.new(
          Pos2.new(screen.left + BORDER_W, @border_top),
          Pos2.new(screen.right - BORDER_W, screen.bottom - BORDER_W))
        painter.rect(client, 0.0, nil, FRAME_INNER, 1.0)
      end
    end

    # ==========================================================================
    # Ubuntu — classic Ambiance (~2017): gradient titlebar, centered
    # title, round buttons at the right edge, close in Ubuntu orange.
    # ==========================================================================
    class Ubuntu < WindowFrame
      CAPTION_H = 28.0  # Ambiance titlebar height
      BTN_D     = 18.0  # round button diameter
      BTN_GAP   = 6.0   # gap between button bounding boxes
      INSET     = 8.0   # inset of the rightmost button from the edge
      TITLE_PT  = 14.0

      # The warm-grey vertical gradient of the Ambiance titlebar.
      BG_TOP    = Color32.new(60, 59, 55, 255)
      BG_BOTTOM = Color32.new(41, 40, 37, 255)
      FG        = Color32.new(255, 255, 255, 255)   # title + glyphs
      # Round buttons: close in Ubuntu orange, the rest dark grey with
      # a lighter hover.
      CLOSE      = Color32.new(233, 84, 32, 255)    # #E95420
      CLOSE_HOT  = Color32.new(245, 105, 50, 255)
      CLOSE_DOWN = Color32.new(210, 70, 22, 255)
      BTN        = Color32.new(64, 62, 58, 255)
      BTN_HOT    = Color32.new(84, 82, 77, 255)
      BTN_DOWN   = Color32.new(50, 48, 45, 255)

      def caption_height : Float64
        CAPTION_H
      end

      def paint_caption(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        painter.rect_gradient(bar.shrink(-1.0), 0.0, BG_TOP, BG_BOTTOM)
      end

      # Ambiance centered the window title.
      def paint_title(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        w = @ctx.fonts.measure(title, TITLE_PT).x
        painter.text(Pos2.new(bar.center.x - w / 2.0, bar.center.y),
          title, TITLE_PT, FG)
      end

      # min / max / close from left to right, round, at the right edge.
      # Centered in the TOP standard strip (a taller caption extends
      # the bar below the buttons, they stay pinned up top).
      def paint_buttons(bar : Rect) : Nil
        cy = bar.top + CAPTION_H / 2.0
        close_x = bar.right - INSET - BTN_D / 2.0
        max_x = close_x - BTN_D - BTN_GAP
        min_x = max_x - BTN_D - BTN_GAP

        round_button(min_x, cy, "minimize", BTN, BTN_HOT, BTN_DOWN)
        round_button(max_x, cy, "maximize", BTN, BTN_HOT, BTN_DOWN)
        round_button(close_x, cy, "close", CLOSE, CLOSE_HOT, CLOSE_DOWN)
      end

      private def round_button(cx : Float64, cy : Float64, name : String,
                               fill : Color32, hover : Color32,
                               down : Color32) : Nil
        rect = Rect.from_min_size(Pos2.new(cx - BTN_D / 2.0, cy - BTN_D / 2.0),
          Vec2.new(BTN_D, BTN_D))
        resp = click_action(rect, name)
        c = rect.center
        painter.layer = Order::Middle
        painter.clip = rect
        circle_fill = if resp.active? && resp.hovered?
          down
        elsif resp.hovered?
          hover
        else
          fill
        end
        painter.circle_filled(c, BTN_D / 2.0, circle_fill)

        # 1px white glyphs inside the circles
        color = FG
        case name
        when "minimize"
          y = (c.y - 0.5).round
          painter.rect(Rect.from_min_size(
            Pos2.new(c.x - 4.0, y), Vec2.new(8.0, 1.0)), 0.0, color, nil, 0.0)
        when "maximize"
          box = Rect.from_min_size(Pos2.new(c.x - 4.0, c.y - 4.0),
            Vec2.new(8.0, 8.0))
          painter.rect(box, 1.0, nil, color, 1.0)
        when "close"
          painter.line(Pos2.new(c.x - 4.0, c.y - 4.0),
            Pos2.new(c.x + 4.0, c.y + 4.0), 1.0, color)
          painter.line(Pos2.new(c.x + 4.0, c.y - 4.0),
            Pos2.new(c.x - 4.0, c.y + 4.0), 1.0, color)
        end
      end
    end

    # ==========================================================================
    # macOS (current): light titlebar with a separator hairline,
    # centered title, traffic lights at the LEFT edge — close, minimize,
    # zoom in Apple's order.
    # ==========================================================================
    class Macos < WindowFrame
      CAPTION_H  = 28.0 # macOS titlebar height
      LIGHT_D    = 16.0 # traffic light diameter
      LIGHT_GAP  = 8.0  # gap between lights
      FIRST_CX   = 24.0 # first light center x from the left edge
      TITLE_PT   = 14.0

      BG_TOP     = Color32.new(243, 243, 243, 255)  # subtle titlebar gradient
      BG_BOTTOM  = Color32.new(233, 233, 233, 255)
      SEPARATOR  = Color32.new(201, 201, 201, 255)  # hairline under the bar
      FG         = Color32.new(60, 60, 64, 255)      # title

      CLOSE = Color32.new(255, 95, 87, 255)   # #FF5F57
      MIN   = Color32.new(254, 188, 46, 255)  # #FEBC2E
      ZOOM  = Color32.new(40, 200, 64, 255)   # #28C840
      # Each light carries a slightly darker ring + a still darker
      # pressed shade (what the real traffic lights do).
      CLOSE_RING = Color32.new(224, 71, 65, 255)   # #E04741
      MIN_RING   = Color32.new(222, 160, 24, 255)
      ZOOM_RING  = Color32.new(34, 170, 55, 255)
      CLOSE_DOWN = Color32.new(214, 55, 49, 255)
      MIN_DOWN   = Color32.new(214, 152, 20, 255)
      ZOOM_DOWN  = Color32.new(28, 158, 50, 255)
      # Glyph shades (macOS darkens the symbols inside the lights).
      CLOSE_GLYPH = Color32.new(130, 0, 0, 255)
      MIN_GLYPH   = Color32.new(150, 95, 0, 255)
      ZOOM_GLYPH  = Color32.new(9, 90, 23, 255)

      def caption_height : Float64
        CAPTION_H
      end

      def paint_caption(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        painter.rect_gradient(bar.shrink(-1.0), 0.0, BG_TOP, BG_BOTTOM)
        # macOS titlebars end in a separator hairline
        painter.rect(Rect.from_min_size(
          Pos2.new(bar.left, bar.bottom), Vec2.new(bar.width, 1.0)),
          0.0, SEPARATOR, nil, 0.0)
      end

      def paint_title(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        w = @ctx.fonts.measure(title, TITLE_PT).x
        painter.text(Pos2.new(bar.center.x - w / 2.0, bar.center.y),
          title, TITLE_PT, FG)
      end

      # Traffic lights: close, minimize, zoom from the left edge. Each
      # light reacts to its OWN hover only — the glyph appears in the
      # hovered circle alone (real macOS reveals the group; per-button
      # is what actually reads clean at this DPI).
      def paint_buttons(bar : Rect) : Nil
        # Lights pinned to the TOP standard strip — a taller caption
        # (content hook) extends the bar below them, like a macOS
        # toolbar area under the titlebar.
        cy = bar.top + CAPTION_H / 2.0
        step = LIGHT_D + LIGHT_GAP
        defs = {
          {FIRST_CX,             "close",    CLOSE, CLOSE_RING, CLOSE_DOWN, CLOSE_GLYPH},
          {FIRST_CX + step,      "minimize", MIN,   MIN_RING,   MIN_DOWN,   MIN_GLYPH},
          {FIRST_CX + 2 * step,  "maximize", ZOOM,  ZOOM_RING,  ZOOM_DOWN,  ZOOM_GLYPH},
        }

        defs.each do |(cx, name, fill, ring, down, glyph_color)|
          rect = Rect.from_min_size(
            Pos2.new(cx - LIGHT_D / 2.0, cy - LIGHT_D / 2.0),
            Vec2.new(LIGHT_D, LIGHT_D))
          resp = click_action(rect, name)
          painter.layer = Order::Middle
          painter.clip = rect
          painter.circle(rect.center, LIGHT_D / 2.0,
            resp.active? && resp.hovered? ? down : fill, ring, 1.0)
          light_glyph(rect, name, glyph_color) if resp.hovered?
        end
      end

      private def light_glyph(rect : Rect, name : String,
                              glyph_color : Color32) : Nil
        painter.layer = Order::Middle
        painter.clip = rect
        c = rect.center
        case name
        when "close"
          painter.line(Pos2.new(c.x - 3.5, c.y - 3.5),
            Pos2.new(c.x + 3.5, c.y + 3.5), 1.0, glyph_color)
          painter.line(Pos2.new(c.x + 3.5, c.y - 3.5),
            Pos2.new(c.x - 3.5, c.y + 3.5), 1.0, glyph_color)
        when "minimize"
          y = (c.y - 0.5).round
          painter.rect(Rect.from_min_size(
            Pos2.new(c.x - 3.5, y), Vec2.new(7.0, 1.0)), 0.0, glyph_color,
            nil, 0.0)
        when "maximize"
          # the zoom symbol: two small triangles pointing outward
          painter.line(Pos2.new(c.x - 2.0, c.y - 3.5),
            Pos2.new(c.x - 4.5, c.y), 1.0, glyph_color)
          painter.line(Pos2.new(c.x - 4.5, c.y),
            Pos2.new(c.x - 2.0, c.y + 3.5), 1.0, glyph_color)
          painter.line(Pos2.new(c.x + 2.0, c.y - 3.5),
            Pos2.new(c.x + 4.5, c.y), 1.0, glyph_color)
          painter.line(Pos2.new(c.x + 4.5, c.y),
            Pos2.new(c.x + 2.0, c.y + 3.5), 1.0, glyph_color)
        end
      end

    end
  end
end
