# Modal dialog / mobile AlertDialog (Material 3 `AlertDialog`, iOS
# alert) — Phase 4 of plans/todo/mobile_widgets.md (#14).
#
# A CENTERED modal card: title, wrapping body text, and a row of up to
# three flat TEXT buttons; everything below is dimmed by the scrim and
# a tap on the scrim dismisses. This is the GENERAL version of
# `AboutModal` (which is the fixed "About this app" page) — the same
# Context-level presenter pattern: the app keeps the open flag and
# calls `#show(ctx)` every frame while open.
#
# Deliberately NOT `Context#modal`: that machinery draws an
# application-dialog shell (h1 title, raised footer band, filled
# buttons). A mobile alert is flatter — no footer band, text buttons
# on the card — so this draws its own scrim/card pair with the same
# tricks (#modal's scrim interact + card claim so blank card space
# never falls through to the scrim, `Memory#layer_sizes` measured
# centering, painter layer/clip save-restore).
#
# The return value is the WHOLE API for outcomes: the clicked button's
# label, `Dialog::SCRIM` on a scrim dismissal, nil when nothing
# happened this frame. Buttons fire exactly once (the click verdict of
# the real pass), so `result = dialog.show(ctx)` per frame is the
# whole integration.
#
# Styling goes through the global `StyleSheet` under the `dialog`
# class (resolved with `StyleSheet#resolve` — no per-widget inspector
# plumbing, same reasoning as `AboutModal`):
#   dialog — width (320), corner_radius (28 — the Material 3 card),
#            button_height (40), button_gap (12, above and below the
#            button row). Scrim dim comes from the theme
#            (`Visuals#modal_dim`), card fill from `window_fill`.
#
#   dialog = Egui::Dialog.new(title: "Delete file?",
#     body: "This cannot be undone.", buttons: ["Cancel", "Delete"])
#   # every frame while @confirm_open:
#   case dialog.show(ctx)
#   when "Delete" then do_delete
#   when Dialog::SCRIM, "Cancel" then @confirm_open = false
#   end

module Egui
  class Dialog
    # The marker `#show` returns the frame the user tapped the scrim
    # (dismissal without picking a button).
    SCRIM = "scrim"
    DEFAULT_WIDTH = 320.0

    getter card_rect : Rect?
    getter id : String

    def initialize(@title : String, @body : String,
                   buttons : Array(String) = [] of String,
                   @width : Float64 = DEFAULT_WIDTH,
                   @id : String = "dialog")
      # Material alerts carry at most three actions.
      @buttons = buttons.first(3)
      @button_rects = {} of String => Rect
      @card_rect = nil
    end

    # The button's rect as laid out THIS frame (nil if absent) — for
    # hit-testing in specs and for anchoring tooltips/popups.
    def button_rect(label : String) : Rect?
      @button_rects[label]?
    end

    # Draw the dialog (call every frame while open). Returns the
    # clicked button's label, `SCRIM` on scrim dismissal, nil when
    # nothing happened this frame.
    def show(ctx : Context) : String?
      result = nil
      @button_rects.clear
      ctx.memory.mark_modal
      root = Id.from("dialog/#{@id}")
      layer = LayerId.new(Order::Foreground, root)
      screen = ctx.input.screen_rect
      v = ctx.style.visuals
      pad = ctx.style.spacing.window_padding
      gap = ctx.style.spacing.item_spacing.x
      vars = ctx.stylesheet.resolve("dialog")
      width = vars.f64?("width") || @width
      width = {width, screen.width}.min if screen.width > 0.0

      ctx.painter.with_layer(layer.z, screen) do
        # Scrim: the dismissal target, declared BEFORE the card so the
        # card's widgets hit-test above it in the same layer.
        ctx.painter.rect(screen, 0.0, v.modal_dim)
        scrim = ctx.interact(Id.from("dialog/#{@id}/scrim"), screen,
          Sense::Click, layer, screen)
        if scrim.clicked?
          result = SCRIM
          ctx.request_repaint
        end

        # Centered on last frame's measured size (first frame: a
        # 180pt-high estimate that settles once the content is
        # measured — the #modal scheme).
        prev_size = ctx.memory.layer_sizes[root]? ||
                    Vec2.new(width, 180.0)
        pos = Pos2.new(screen.center.x - prev_size.x / 2.0,
          screen.center.y - prev_size.y / 2.0)
        card = Rect.from_min_size(pos, prev_size)
        @card_rect = card

        # The card itself as a click claim, ABOVE the scrim: a tap on
        # blank card space dies on the card instead of dismissing.
        ctx.interact(Id.from("dialog/#{@id}/card"), card, Sense::Click,
          layer, card)
        ctx.painter.rect(card, vars.f64("corner_radius", 28.0),
          v.window_fill, Color32.rgba(v.window_stroke.r,
          v.window_stroke.g, v.window_stroke.b, 90), 1.0)

        # Content: title + wrapping body in one top-down flow; the
        # button row hangs under the flow's bottom (equal-width
        # stretched text buttons — the mobile alert's flat actions).
        ctx.memory.use_id(root)
        ui = Ui.new(ctx, root,
          Rect.from_min_size(pos + pad,
            Vec2.new(width - 2.0 * pad.x, 1e6)))
        ui.layer = layer
        ctx.painter.clip = card
        ui.heading(@title) unless @title.empty?
        ui.label(@body) unless @body.empty?
        content_bottom = ui.min_rect.bottom

        card_h = if @buttons.empty?
                   content_bottom + pad.y - pos.y
                 else
                   btn_h = vars.f64("button_height", 40.0)
                   btn_pad = vars.f64("button_gap", 12.0)
                   row_top = content_bottom + btn_pad
                   row = ui.child_ui(
                     Rect.from_min_size(Pos2.new(pos.x + pad.x, row_top),
                       Vec2.new(width - 2.0 * pad.x, btn_h)),
                     layout: Layout.left_to_right)
                   n = @buttons.size
                   bw = (width - 2.0 * pad.x - (n - 1) * gap) / n
                   @buttons.each do |label|
                     resp = row.add(Button.new(label,
                       id: "dialog/#{@id}/#{label}")
                       .min_size(Vec2.new(bw, btn_h))
                       .style { |s| s.background = Color32.transparent })
                     @button_rects[label] = resp.rect
                     result = label if resp.clicked?
                   end
                   row_top + btn_h + btn_pad - pos.y
                 end
        ctx.memory.layer_sizes[root] = Vec2.new(width, card_h)
      end

      result
    end
  end
end
