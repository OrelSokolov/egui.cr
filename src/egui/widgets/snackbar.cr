# Mobile Snackbar / Toast (Material 3 `Snackbar`) — plans/todo/
# mobile_widgets.md #2, Phase 1.
#
# A transient message bar pinned to the bottom of the screen over the
# app's content: dark rounded rect, one line of text, an optional
# trailing ACTION label. v1 is app-driven: the app holds the "which
# toast, until when" state and passes `visible:` (a timed auto-hide
# needs a timer port — the app flips `visible` back after its own
# delay, e.g. from a reactive timer). The widget paints nothing and
# reserves nothing when not visible, so it can be called every frame.
#
# Pinning: the sugar helper wraps the bar in an `Overlay` anchored
# bottom_center (see widgets/overlay.cr) — no layout flow impact.
# Lift it above a BottomNav with the `lift:` margin parameter.
#
# Styling — the `snackbar` class: `background`, `text_color`,
# `action_color`, `height` (48), `rounding` (8), `font_size`,
# `side_padding` (16), `inner_gap` (12). The whole bar is one click
# target; a tap is reported through `Response#clicked?`/`changed?`
# and the optional action block fires on click when the label shows.

module Egui
  class Snackbar
    include Widget

    def initialize(@text : String, @action_text : String? = nil,
                   @visible : Bool = true, id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "snackbar"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("background", :color),
        StyleProp.new("text_color", :color),
        StyleProp.new("action_color", :color),
        StyleProp.new("height", :number, min: 0.0),
        StyleProp.new("rounding", :number, min: 0.0),
        StyleProp.new("font_size", :number, min: 0.0),
        StyleProp.new("side_padding", :number, min: 0.0),
        StyleProp.new("inner_gap", :number, min: 0.0),
      ]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      visuals = style.visuals
      vars = style_vars(ui, id)
      empty = Response.new(ui.ctx, id, Rect.zero, Sense.none,
        false, false, 0, false, false, false, false, false, Vec2.zero)
      return empty unless @visible

      # Measure the text to size the bar (one line, clipped — the
      # Material bar truncates rather than wraps).
      font_size = vars.f64("font_size", style.font_size)
      fonts, family, bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      text_size = fonts.measure(@text, font_size)
      pad = vars.f64("side_padding", 16.0)
      gap = vars.f64("inner_gap", 12.0)
      action_size = @action_text ? fonts.measure(@action_text.not_nil!, font_size) : Vec2.zero
      h = vars.f64("height", 48.0)
      w = pad + text_size.x +
          (@action_text ? gap + action_size.x + pad : pad)
      size = styled_size(Vec2.new(w, h), vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click)

      rounding = vars.rounding_px("rounding", rect, 8.0)
      ui.painter.rect(rect, rounding,
        vars.color("background", Color32.rgb(50, 50, 50)))
      ui.painter.text(Pos2.new(rect.left + pad, rect.center.y), @text,
        font_size, vars.color("text_color", Color32.rgb(255, 255, 255)),
        family: family, bold: bold)
      if (action = @action_text)
        ui.painter.text(
          Pos2.new(rect.right - pad - action_size.x, rect.center.y), action,
          font_size, vars.color("action_color", visuals.selection_fill),
          family: family, bold: true)
      end

      response.mark_changed if response.clicked?
      response
    end
  end
end

class Egui::Ui
  # `ui.snackbar(id, "Saved", action_text: "UNDO") { … }` — visible
  # bars anchor bottom_center over this Ui's region; `lift:` raises
  # the bar above a bottom navigation (pass its height). Invisible →
  # a no-op response, nothing painted. Clicking the bar fires the
  # block and reports `changed?`.
  def snackbar(id : String, text : String, visible : Bool,
               action_text : String? = nil, lift : Float64 = 0.0,
               &on_action : ->) : Response
    unless visible
      return Response.new(ctx, Id.from(id), Rect.zero, Sense.none,
        false, false, 0, false, false, false, false, false, Vec2.zero)
    end
    overlay(:bottom_center,
      margin: StyleBox.new(bottom: 16.0 + lift, left: 16.0, right: 16.0),
      id: "#{id}/overlay", pass_through: true) do |o|
      bar = o.add(Snackbar.new(text, action_text, visible: true, id: id))
      if bar.clicked?
        on_action.call
        bar.mark_changed
      end
      bar
    end
  end
end
