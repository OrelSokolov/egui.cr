# Mobile tooltip (Material 3 "plain tooltip" / iOS HIG popover-lite) —
# plans/todo/mobile_widgets.md #23.
#
# Response#on_hover_text already carries the DESKTOP egui tooltip: it
# shows at the POINTER after a fixed 0.5 s hover. The mobile variant is
# a separate widget because its trigger and its anchor both differ:
#
# * trigger — a finger has no hover. On touch (pointer_coarse? or the
#   touch_pointer latch, so hybrid devices follow whichever was touched
#   last) the tip arms while the finger HOLDS the body down and shows
#   after ~0.5 s of that long-press; on a mouse it arms while hovered
#   and shows after ~0.7 s (the longer delay on purpose: hover is
#   often incidental — a pointer passing over the control must not
#   flash text, a held finger is deliberate and blocks the content
#   anyway). Release / unhover disarms instantly.
# * anchor — near the WIDGET (centered under it, Material style), not
#   at the pointer: on touch there is no stable pointer position after
#   release, and a finger hides the very spot it touches.
#
# The bubble is a plain dark capsule-ish rect (no pointer arrow in v1 —
# Material's plain tooltip has none either), painted in the Tooltip
# layer (top z, above menus) and NON-interactive: it never steals
# clicks. Single-line text (no wrap) in v1; long labels are the app's
# problem, not the tooltip's.
#
# The wrapper has no state of its own, so `#ui` returns the BODY's
# Response verbatim (no mark_changed — a click on the body is the body
# widget's semantics; the tooltip only observes it). The body block
# must return the Response of the widget to hover/long-press:
#
#   ui.tooltip("save_tip", "Saves the current document") do |ui|
#     ui.button("Save")   # last expression = the tracked Response
#   end
#
# Styling — the `tooltip` class: `delay` (seconds; class rule beats the
# constructor's `delay:`), `background`, `text_color`, `font_size`,
# `offset` (gap between the widget and the bubble). Defaults are fixed
# near-black/white on purpose — a tooltip is INVERSE of the theme by
# convention (dark bubble on light themes too), so theme slots would
# be the wrong fallback.

module Egui
  class Tooltip
    include Widget

    DEFAULT_HOVER_DELAY       = 0.7
    DEFAULT_LONG_PRESS_DELAY  = 0.5
    DEFAULT_BACKGROUND = Color32.rgba(30, 30, 32, 245)
    DEFAULT_TEXT       = Color32.rgba(255, 255, 255, 240)

    def initialize(@text : String, id : String? = nil,
                   @delay : Float64? = nil, &body : Ui -> Response)
      @id_name = id
      @body = body
    end

    def style_class : String?
      "tooltip"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("delay", :number, min: 0.0),
        StyleProp.new("background", :color),
        StyleProp.new("text_color", :color),
        StyleProp.new("font_size", :number, min: 0.0),
        StyleProp.new("offset", :number, min: 0.0),
      ]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      ctx = ui.ctx
      vars = style_vars(ui, id)
      style = effective_style(ui, id)

      body = @body.call(ui)

      # Arm/show state machine, keyed by the tooltip's own id in the
      # long-term memory: the stored value is the arm START time
      # (0 = not armed). `use_id` keeps the cell alive across end-frame
      # pruning while the tooltip sits unhovered for frames on end.
      now = ctx.input.time
      coarse = ctx.pointer_coarse? || ctx.input.touch_pointer?
      # Touch: long-press WHILE pressed (a bare hovered? would show
      # during the flick-past of a finger drag). pressed? only covers
      # click-sense bodies, so fall back to "pointer is down over the
      # body" — a long-press on a Label works the same as on a Button.
      trigger = if coarse
        body.pressed? || (ctx.input.pointer_down? && body.hovered?)
      else
        body.hovered?
      end
      delay = vars.f64("delay",
        @delay || (coarse ? DEFAULT_LONG_PRESS_DELAY : DEFAULT_HOVER_DELAY))

      ctx.memory.use_id(id)
      start = ctx.memory.data.get_f64(id, 0.0)
      showing = false
      if trigger
        start = now if start <= 0.0
        ctx.memory.data.set_f64(id, start)
        showing = now - start >= delay
        # Keep the frame loop alive while the countdown runs — the
        # bubble must appear even if the user's hand is perfectly
        # still and no input event ever fires again.
        ctx.request_repaint unless showing
      elsif start > 0.0
        # Release / unhover: disarm, hide instantly (no fade in v1).
        ctx.memory.data.set_f64(id, 0.0)
      end

      paint(ui, body.rect, vars, style) if showing
      body
    end

    # The bubble: centered under the body (flipped above when it would
    # run past the screen bottom), clamped fully inside the screen.
    # Layer + clip are saved/restored around the paint — the painter is
    # SHARED, and both the Tooltip layer and the tight bubble clip would
    # otherwise leak into every widget painted later in the frame (the
    # same fix Response#paint_tooltip_bubble applies).
    private def paint(ui : Ui, anchor : Rect, vars : StyleVars,
                      style : Style) : Nil
      ctx = ui.ctx
      painter = ctx.painter
      font_size = vars.f64("font_size", style.font_size * 0.9)
      text_size = ui.fonts.measure(@text, font_size)
      margin = Vec2.new(6.0, 4.0)
      size = text_size + margin * 2.0
      offset = vars.f64("offset", 6.0)
      screen = ctx.input.screen_rect

      x = anchor.center.x - size.x / 2.0
      y = anchor.bottom + offset
      if screen.width > 0.0 && y + size.y > screen.bottom
        y = anchor.top - offset - size.y
      end
      if screen.width > 0.0
        x = { {x, screen.right - size.x}.min, screen.left }.max
        y = { {y, screen.bottom - size.y}.min, screen.top }.max
      end
      pos = Pos2.new(x, y)

      saved_layer = painter.layer
      saved_clip = painter.clip
      painter.layer = Order::Tooltip
      painter.clip = Rect.from_min_size(pos, size)
      painter.rect(Rect.from_min_size(pos, size), 4.0,
        vars.color("background", DEFAULT_BACKGROUND))
      # Painter#text anchors the LEFT-CENTER — pass the center of the
      # margin-padded text area (pos + margin alone shifts the glyphs
      # up half a line, under the top border).
      painter.text(Pos2.new(pos.x + margin.x, pos.y + margin.y + text_size.y / 2.0),
        @text, font_size, vars.color("text_color", DEFAULT_TEXT))
      painter.layer = saved_layer
      painter.clip = saved_clip
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.tooltip(id, text) { |ui| body }` — wraps a body widget; the
  # block must return the body's Response (the widget to hover /
  # long-press). `delay:` (seconds) overrides the platform default
  # (0.7 hover / 0.5 long-press); a `tooltip { delay }` class rule
  # beats it. Returns the body's Response verbatim.
  def tooltip(id : String, text : String, delay : Float64? = nil,
              &body : Ui -> Response) : Response
    add(Tooltip.new(text, id: id, delay: delay, &body))
  end
end
