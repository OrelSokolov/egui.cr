# Bottom sheet (Material 3 `ModalBottomSheet` / iOS detent sheet) —
# Phase 4 of plans/todo/mobile_widgets.md (#13).
#
# v1 scope, honestly: a MODAL sheet anchored to the screen's bottom
# edge, full-width, over a dimmed scrim. The app owns the open flag
# exactly like `AboutModal` — it creates one `BottomSheet`, calls
# `#show(ctx)` every frame while open, and drops the flag when `#show`
# returns true (the frame the user tapped the scrim). A drag HANDLE
# BAR is drawn at the sheet's top center, but v1 does not implement
# drag-to-dismiss or detent positions (half/full): dragging a sheet
# means pointer capture that must cooperate with an arbitrary scroll
# body (the same overscroll/gesture hand-off `ScrollArea` does not
# expose yet — see plan #15 and the pull_to_refresh header). Tapping
# the scrim is the close gesture; a programmatic close is the app
# simply stopping to call `#show`.
#
# The slide is a `Spring` (spring.cr) stored on the instance, stepped
# with `Context#input.dt` — frame-rate independent (exact closed-form
# solution), velocity-continuous while frames keep coming. Every open
# starts from rest at the bottom edge: a scrim dismissal re-arms the
# slide for the next open automatically; for a PROGRAMMATIC close +
# reopen the app should call `#open` before the first `#show` (the
# sheet cannot see the gap — it only knows the frames it is shown
# in). While the spring moves, frames are requested via
# `Context#request_repaint`; at rest the sheet costs nothing.
#
# Styling goes through the global `StyleSheet` under the
# `bottom_sheet` class (resolved with `StyleSheet#resolve` — this is
# a Context-level presenter like `AboutModal`, not a flow `Widget`,
# so it carries no per-widget inspector plumbing):
#   bottom_sheet — corner_radius (12, the TOP corners; the bottom
#                  edge sits on the screen and stays square),
#                  handle_width (36), handle_height (4; 0 disables
#                  the bar), handle_color (nil = separator_color),
#                  max_height_share (0.7 — the sheet never grows past
#                  this fraction of the screen; taller bodies scroll
#                  inside), slide_response (0.35 — spring period in
#                  seconds), slide_damping (1.0 = critically damped;
#                  < 1 bounces).
#
#   sheet = Egui::BottomSheet.new(id: "filters")
#   # every frame while @filters_open:
#   @filters_open = false if sheet.show(ctx) do |ui|
#     ui.label("Filter by…")
#   end

module Egui
  class BottomSheet
    # Reserved strip above the body where the handle bar sits.
    HANDLE_ZONE = 32.0
    # First-frame height estimate until the body is measured (the
    # `Memory#layer_sizes` scheme `#modal`/`#overlay` use — the sheet
    # settles once its content is first measured).
    ESTIMATE_H = 240.0

    getter sheet_rect : Rect?
    getter handle_rect : Rect?
    getter id : String

    def initialize(@id : String = "sheet")
      @spring = Spring.new(0.0)
      @closed_last = false
      @sheet_rect = nil
      @handle_rect = nil
    end

    # Seat the spring at the bottom edge — call before the FIRST
    # `#show` of a programmatic open to make it slide. A scrim
    # dismissal re-arms the slide by itself; calling this redundantly
    # is harmless.
    def open : Nil
      @spring.set(0.0)
    end

    # Draw the sheet (call every frame while open). True the frame the
    # user dismissed it (scrim tap) — the caller then clears its open
    # flag. The body block lays out into a top-down Ui occupying the
    # sheet width minus the window padding; it re-runs every frame.
    def show(ctx : Context, &body : Ui ->) : Bool
      closed = false
      ctx.memory.mark_modal
      root = Id.from("sheet/#{@id}")
      layer = LayerId.new(Order::Foreground, root)
      screen = ctx.input.screen_rect
      v = ctx.style.visuals
      pad = ctx.style.spacing.window_padding
      vars = ctx.stylesheet.resolve("bottom_sheet")
      width = screen.width

      ctx.painter.with_layer(layer.z, screen) do
        # Slide progress 0..1. A scrim dismissal last time re-seats
        # the spring so the next open slides from the edge.
        if @closed_last
          @spring.set(0.0)
          @closed_last = false
        end
        @spring.step(ctx.input.dt, 1.0,
          vars.f64("slide_response", 0.35),
          vars.f64("slide_damping", 1.0))
        ctx.request_repaint if @spring.moving?(1.0)
        t = @spring.value.clamp(0.0, 1.0)

        # Scrim over everything below, fading in with the same
        # progress (theme-driven dim — `Visuals#modal_dim`). A click
        # target: tap outside the sheet dismisses.
        dim = v.modal_dim
        ctx.painter.rect(screen, 0.0, Color32.rgba(
          dim.r, dim.g, dim.b, (dim.a.to_f64 * t).round.to_i))
        scrim = ctx.interact(Id.from("sheet/#{@id}/scrim"), screen,
          Sense::Click, layer, screen)
        if scrim.clicked?
          closed = true
          ctx.request_repaint
        end

        # Geometry: full width, content-driven height (capped by
        # max_height_share), anchored to the bottom edge — the spring
        # slides it up from below the screen (t < 1 leaves the sheet's
        # bottom edge off-screen, which is the slide).
        prev_h = (ctx.memory.layer_sizes[root]? ||
                  Vec2.new(width, ESTIMATE_H)).y
        h = {prev_h, screen.height * vars.f64("max_height_share", 0.7)}.min
        y = screen.bottom - h * t
        rect = Rect.from_min_size(Pos2.new(0.0, y), Vec2.new(width, h))
        @sheet_rect = rect

        # Blank sheet space eats clicks (the card claim is registered
        # before the content — the same scrim/card pair `#modal` uses:
        # a tap on the sheet body must not fall through to the scrim).
        ctx.interact(Id.from("sheet/#{@id}/card"), rect, Sense::Click,
          layer, rect)

        # Shell: rounded TOP corners, square bottom — the rounded
        # shell is painted past the screen's bottom edge and a square
        # patch fills its rounding back to a straight edge, the same
        # trick `#modal`'s footer band uses.
        radius = vars.f64("corner_radius", 12.0)
        ctx.painter.rect(Rect.new(rect.min,
          Pos2.new(rect.right, screen.bottom + radius + 1.0)),
          radius, v.window_fill, nil, 0.0)
        ctx.painter.rect(Rect.from_min_size(
          Pos2.new(rect.left, screen.bottom - 1.0),
          Vec2.new(width, radius + 2.0)), 0.0, v.window_fill, nil, 0.0)

        # The drag handle bar — drawn only in v1 (see header).
        hh = vars.f64("handle_height", 4.0)
        if hh > 0.0
          hw = vars.f64("handle_width", 36.0)
          hrect = Rect.from_min_size(
            Pos2.new(width / 2.0 - hw / 2.0,
              rect.top + (HANDLE_ZONE - hh) / 2.0),
            Vec2.new(hw, hh))
          ctx.painter.rect(hrect, hh / 2.0,
            vars.color?("handle_color") || v.separator_color, nil, 0.0)
          @handle_rect = hrect
        else
          @handle_rect = nil
        end

        # The body.
        ctx.memory.use_id(root)
        ui = Ui.new(ctx, root,
          Rect.from_min_size(Pos2.new(pad.x, rect.top + HANDLE_ZONE),
            Vec2.new(width - 2.0 * pad.x, 1e6)))
        ui.layer = layer
        ctx.painter.clip = rect
        body.call(ui)
        ctx.memory.layer_sizes[root] =
          Vec2.new(width, ui.min_rect.bottom + pad.y - rect.top)
      end

      @closed_last = true if closed
      closed
    end
  end
end
