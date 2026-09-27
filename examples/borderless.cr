# egui-cr: borderless window demo — custom chrome instead of the system
# frame (the eframe `decorations: false` setup).
#
# `Egui::Backend::Sokol.run(decorations: false)` strips the system title
# bar at startup; this app then draws its own title bar (drag to move,
# double-click to maximize, close/minimize/maximize buttons) and its own
# resize grips along the window edges. Everything goes through the
# SystemPorts (Quit, Window, Screen) — the seams a per-platform backend
# implements, so the same code runs on X11/Win32/macOS.
#
# The decorations can also be toggled back at runtime through the
# Window port (checkbox below) to demo the runtime path.

require "../src/egui"
require "../src/egui/backend/sokol"

class BorderlessApp < Egui::App
  TITLE  = "egui-cr — borderless"
  BTN_W  = 42.0  # caption button width
  BTN_IN = 12.0  # caption icon inset
  EDGE   = 6.0   # resize grip thickness (points)

  @decorated = false
  @maximized = false

  def update(ctx : Egui::Context) : Nil
    screen = ctx.input.screen_rect

    # Reserve the top strip; the strip rect (painting + interaction)
    # is handled by #title_bar below.
    bar = ctx.top_panel("titlebar") { }

    # Edge grips first, so panel widgets on the same Background layer
    # still win hit-tests over the 6px rim.
    resize_edges(ctx, screen)

    title_bar(ctx, bar)

    ctx.central_panel do |ui|
      ui.heading("Borderless window")
      ui.label("System chrome is off: this title bar, the caption buttons " \
               "and the edge grips are all egui widgets.")
      ui.label("Drag the title bar to move, double-click it to maximize, " \
               "drag any edge/corner to resize.")

      resp = ui.checkbox(@decorated, "System decorations (runtime toggle)")
      if resp.changed?
        @decorated = !@decorated
        Egui::SystemPorts::Window.set_decorations(@decorated)
      end

      if ui.button(@maximized ? "Restore" : "Maximize").clicked?
        toggle_maximize
      end
      if ui.button("Minimize").clicked?
        Egui::SystemPorts::Window.minimize
      end
      if ui.button("Quit").clicked?
        Egui::SystemPorts::Quit.quit!
      end

      if (pos = Egui::SystemPorts::Window.position)
        scale = Egui::SystemPorts::Screen.dpi_scale
        ui.label("window @ (#{"%.0f" % pos.x}, #{"%.0f" % pos.y}) px, " \
                 "#{"%.0f" % screen.width}×#{"%.0f" % screen.height} pt, " \
                 "dpi #{"%.1f" % scale}")
      end
    end
  end

  # --- title bar ------------------------------------------------------------

  private def title_bar(ctx : Egui::Context, bar : Egui::Rect) : Nil
    style = ctx.style
    visuals = style.visuals
    painter = ctx.painter

    # Drag strip (Background layer): drag start hands the move to the
    # platform's native window-move loop (WM/compositor tracks the
    # pointer — a client-side move loop measured in window-local
    # pointer coords feeds back on its own moves and jitters),
    # double-click toggles maximize — the two things a system title
    # bar does.
    drag_id = Egui::Id.from("borderless/titlebar/drag")
    drag = ctx.interact(drag_id, bar, Egui::Sense.click_and_drag,
      Egui::LayerId.background, bar)
    if drag.drag_started?
      Egui::SystemPorts::Window.start_drag
    end
    if drag.double_clicked?
      toggle_maximize
    end

    # Caption buttons ride a Middle layer (z=50) so they win hit-tests
    # over the drag strip (z=0) underneath.
    btn_layer = Egui::LayerId.new(Egui::Order::Middle,
      Egui::Id.from("borderless/titlebar/buttons"))

    y = bar.top
    h = bar.height
    close = Egui::Rect.from_min_size(
      Egui::Pos2.new(bar.right - BTN_W, y), Egui::Vec2.new(BTN_W, h))
    max = Egui::Rect.from_min_size(
      Egui::Pos2.new(close.left - BTN_W, y), Egui::Vec2.new(BTN_W, h))
    min = Egui::Rect.from_min_size(
      Egui::Pos2.new(max.left - BTN_W, y), Egui::Vec2.new(BTN_W, h))

    if caption_button(ctx, min, btn_layer, "minimize").clicked?
      Egui::SystemPorts::Window.minimize
    end
    if caption_button(ctx, max, btn_layer, "maximize").clicked?
      toggle_maximize
    end
    if caption_button(ctx, close, btn_layer, "close").clicked?
      Egui::SystemPorts::Quit.quit!
    end

    # Paint after the interactions: strip fill, hairline separator,
    # title, button glyphs.
    painter.layer = Egui::Order::Background
    painter.clip = bar
    painter.rect(bar, 0.0, visuals.panel_fill, nil, 0.0)
    painter.line(Egui::Pos2.new(bar.left, bar.bottom),
      Egui::Pos2.new(bar.right, bar.bottom), 1.0, visuals.window_stroke)
    painter.text(Egui::Pos2.new(bar.left + 10.0, bar.center.y),
      TITLE, style.font_size, visuals.text_color)

    caption_icon(painter, "minimize", min, visuals.text_color)
    caption_icon(painter, "maximize", max, visuals.text_color)
    caption_icon(painter, "close", close,
      @close_hover ? Egui::Color32.new(235, 235, 235, 255) : visuals.text_color)
  end

  @close_hover = false

  # A square caption button: hover/press fill + a click Response. The
  # glyph is painted later (#caption_icon) so hover state and painting
  # stay in one place per button.
  private def caption_button(ctx : Egui::Context, rect : Egui::Rect,
                             layer : Egui::LayerId, name : String) : Egui::Response
    resp = ctx.interact(Egui::Id.from("borderless/titlebar/#{name}"),
      rect, Egui::Sense.click, layer, rect)
    @close_hover = resp.hovered? && name == "close"

    painter = ctx.painter
    painter.layer = layer.order
    painter.clip = rect
    fill = if resp.active?
      Egui::Color32.new(255, 255, 255, 51)
    elsif resp.hovered?
      name == "close" ? Egui::Color32.new(227, 27, 61, 255) :
        Egui::Color32.new(255, 255, 255, 26)
    end
    painter.rect(rect, 0.0, fill, nil, 0.0)
    resp
  end

  private def caption_icon(painter : Egui::Painter, name : String,
                           rect : Egui::Rect, color : Egui::Color32) : Nil
    painter.layer = Egui::Order::Middle
    painter.clip = rect
    inner = rect.shrink(BTN_IN * 0.5)
    case name
    when "minimize"
      Egui::Icons.draw(painter, :minus, inner, color, 2.0)
    when "close"
      Egui::Icons.draw(painter, :close, inner, color, 2.0)
    when "maximize"
      if @maximized
        # restore: two overlapping square outlines
        painter.rect(inner.translate(Egui::Vec2.new(3.0, -3.0)), 1.0,
          nil, color, 1.5)
        painter.rect(inner, 1.0, nil, color, 1.5)
      else
        painter.rect(inner, 1.0, nil, color, 1.5)
      end
    end
  end

  private def toggle_maximize : Nil
    if @maximized
      Egui::SystemPorts::Window.restore
      @maximized = false
    else
      Egui::SystemPorts::Window.maximize
      @maximized = true
    end
  end

  # --- edge resize grips ------------------------------------------------------

  # Grips along the window rim: hover/drag set the resize cursor, drag
  # start hands the resize to the native loop (same rationale as the
  # title bar — the compositor does the tracking).
  private def resize_edges(ctx : Egui::Context, screen : Egui::Rect) : Nil
    e = EDGE
    grips = {
      {Egui::CursorIcon::EwResize, Egui::Rect.from_min_size(screen.min,
        Egui::Vec2.new(e, screen.height)), :left},
      {Egui::CursorIcon::EwResize, Egui::Rect.from_min_size(
        Egui::Pos2.new(screen.right - e, screen.top),
        Egui::Vec2.new(e, screen.height)), :right},
      {Egui::CursorIcon::NsResize, Egui::Rect.from_min_size(screen.min,
        Egui::Vec2.new(screen.width, e)), :top},
      {Egui::CursorIcon::NsResize, Egui::Rect.from_min_size(
        Egui::Pos2.new(screen.left, screen.bottom - e),
        Egui::Vec2.new(screen.width, e)), :bottom},
      {Egui::CursorIcon::NwseResize, Egui::Rect.from_min_size(
        Egui::Pos2.new(screen.right - e * 2, screen.bottom - e * 2),
        Egui::Vec2.new(e * 2, e * 2)), :bottom_right},
    }

    grips.each_with_index do |(icon, rect, edge), i|
      resp = ctx.interact(Egui::Id.from("borderless/resize/#{i}"),
        rect, Egui::Sense.drag, Egui::LayerId.background, rect)
      resp.on_hover_and_drag_cursor(icon)
      if resp.drag_started?
        Egui::SystemPorts::Window.start_resize(edge)
      end
    end
  end
end

Egui::Backend::Sokol.run(BorderlessApp.new,
  title: "egui-cr — borderless", decorations: false)
