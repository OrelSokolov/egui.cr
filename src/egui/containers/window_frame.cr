# egui.cr-native container (no upstream counterpart): a client-side
# window frame drawn after the platform chrome of your choice — the
# default borderless look of `Egui::Backend::Sokol.run(decorations:
# false)` (see the `chrome:`/`chrome_style:` options there).
#
# Three styles (WindowFrame::Style) — they change ONLY the top caption
# panel; the 1px window outline and all behavior are shared:
#   * Windows — Windows 11 dark: 32pt #202020 caption, 46×32 caption
#     buttons, #C42B1C close hover.
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

module Egui
  class WindowFrame
    enum Style
      Windows
      Ubuntu
      Macos
    end

    EDGE = 6.0 # resize grip thickness (points)

    def self.show(ctx : Context, title : String,
                  style : Style = Style::Windows) : Nil
      frame = case style
              in Style::Windows then Windows.new(ctx, title)
              in Style::Ubuntu  then Ubuntu.new(ctx, title)
              in Style::Macos   then Macos.new(ctx, title)
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

      bar = @ctx.top_panel("window_frame/caption", height: caption_height) { }
      handle_drag(bar)
      paint_caption(bar)
      paint_title(bar)
      paint_buttons(bar)
      paint_border(screen)
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

    # The window outline — SHARED by every style (only the caption
    # differs between looks): four pixel-aligned 1px solid bars,
    # painted above every panel (z just under the popup layer) so the
    # central panel's fill cannot cover them.
    BORDER = Color32.new(58, 58, 58, 255) # 1px window outline

    def paint_border(screen : Rect) : Nil
      painter.layer = POPUP_LAYER_Z - 1
      painter.clip = screen
      w = screen.width
      h = screen.height
      painter.rect(Rect.from_min_size(screen.min, Vec2.new(w, 1.0)),
        0.0, BORDER, nil, 0.0)
      painter.rect(Rect.from_min_size(
        Pos2.new(screen.left, screen.bottom - 1.0), Vec2.new(w, 1.0)),
        0.0, BORDER, nil, 0.0)
      painter.rect(Rect.from_min_size(screen.min, Vec2.new(1.0, h)),
        0.0, BORDER, nil, 0.0)
      painter.rect(Rect.from_min_size(
        Pos2.new(screen.right - 1.0, screen.top), Vec2.new(1.0, h)),
        0.0, BORDER, nil, 0.0)
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
    # Windows 11 (dark)
    # ==========================================================================
    class Windows < WindowFrame
      CAPTION_H = 32.0 # Win11 caption height (px @ 100%)
      BTN_W     = 46.0 # caption button width
      BTN_H     = CAPTION_H
      GLYPH     = 10.0 # caption glyph box (Segoe Fluent icons, 1px)
      TITLE_PAD = 16.0 # title text inset from the left edge
      TITLE_PT  = 14.0 # caption font

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

      def caption_height : Float64
        CAPTION_H
      end

      def paint_caption(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        painter.rect(bar.shrink(-1.0), 0.0, BG, nil, 0.0)
      end

      def paint_title(bar : Rect) : Nil
        painter.layer = 1
        painter.clip = bar.shrink(-1.0)
        painter.text(Pos2.new(bar.left + TITLE_PAD, bar.center.y),
          title, TITLE_PT, FG)
      end

      def paint_buttons(bar : Rect) : Nil
        close = Rect.from_min_size(
          Pos2.new(bar.right - BTN_W, bar.top), Vec2.new(BTN_W, BTN_H))
        max = Rect.from_min_size(
          Pos2.new(close.left - BTN_W, bar.top), Vec2.new(BTN_W, BTN_H))
        min = Rect.from_min_size(
          Pos2.new(max.left - BTN_W, bar.top), Vec2.new(BTN_W, BTN_H))

        button(min, "minimize")
        button(max, "maximize")
        button(close, "close")

        glyph("minimize", min, FG)
        glyph("maximize", max, FG)
        glyph("close", close, FG)
      end

      # A square caption button: hover/press fill (Win11 overlay colors)
      # + a click Response. The glyph is painted by #glyph.
      private def button(rect : Rect, name : String) : Response
        resp = click_action(rect, name)
        painter.layer = Order::Middle
        painter.clip = rect
        fill = if resp.active? && resp.hovered?
          name == "close" ? CLOSE_PRESSED : PRESSED_FILL
        elsif resp.hovered?
          name == "close" ? CLOSE_HOVER : HOVER_FILL
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
      def paint_buttons(bar : Rect) : Nil
        cy = bar.center.y
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
        cy = bar.center.y
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
