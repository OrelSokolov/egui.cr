# Pull-to-refresh indicator — Phase 4 of plans/todo/mobile_widgets.md
# (#15), v1 honestly scoped.
#
# What v1 IS: the REFRESHING side of the gesture. The app places the
# widget directly ABOVE its scrollable content; while `refreshing` is
# true it reserves a spinner strip (default 56pt tall, full width —
# Material's drop circle simplified to a centered spinning arc, the
# same painter primitive and repaint contract as `Spinner`: frames are
# requested only while the strip is visible and not culled), plus an
# optional status label to its right. When the work is done the app
# flips the flag and the strip collapses to zero height.
#
# What v1 is NOT: the gesture itself. Firing an `on_refresh` callback
# requires knowing the scroll content is dragged PAST its top edge —
# an overscroll signal `ScrollArea` does not expose yet (plan #15:
# first "expose overscroll", then wire the drag threshold). Until then
# the HOOK POINT is the app state that flips `refreshing` — today a
# refresh button / network event; tomorrow the overscroll check, which
# only needs to set the same flag. This widget's contract will not
# change when the gesture lands. Drag-to-dismiss of the
# `bottom_sheet` hits the same missing primitive — one fix serves
# both.
#
# Modeled on `Switch` (the Phase 1 reference): `include Widget`,
# `style_class` + `style_properties`, `resolve_id`/`effective_style`/
# `style_vars`, `Sense.none` (the strip is not clickable), a
# spinner-style repaint contract.
#
# Styling — the `pull_to_refresh` class: `strip_height` (56),
# `spinner_size` (24), `color` (nil = text_color), `label_size` (14).

module Egui
  class PullToRefresh
    include Widget

    def initialize(@refreshing : Bool, id : String? = nil,
                   @label : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "pull_to_refresh"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("strip_height", :number, min: 0.0, fallback: 56.0),
        StyleProp.new("spinner_size", :number, min: 0.0, fallback: 24.0),
        StyleProp.new("color", :color),
        StyleProp.new("label_size", :number, min: 0.0, fallback: 14.0),
      ]
    end

    def inspector_label : String?
      @refreshing ? "refreshing" : "idle"
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      visuals = style.visuals
      vars = style_vars(ui, id)
      strip_h = @refreshing ? vars.f64("strip_height", 56.0) : 0.0
      rect = ui.allocate_at_least(Vec2.new(ui.available_width, strip_h))

      if @refreshing
        # The spinner keeps rotating from input time — request frames
        # only while the strip meets the clip (the `Spinner` visibility
        # contract: a culled indicator must not pin the repaint loop).
        ui.ctx.request_repaint if rect.intersects?(ui.clip)
        size = vars.f64("spinner_size", 24.0)
        color = vars.color("color", visuals.text_color)
        center = Pos2.new(rect.center.x, rect.center.y)
        tau = 2.0 * Math::PI
        angle = (ui.ctx.input.time * tau / 3.0) % tau
        ui.painter.arc(center, size / 2.0 - 1.5, angle,
          angle + tau * 0.3, 2.0, color)
        if (text = @label)
          ui.painter.text(
            Pos2.new(center.x + size / 2.0 + 12.0, center.y), text,
            vars.f64("label_size", 14.0), color)
        end
      end

      ui.interact(rect, id, Sense.none)
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.pull_to_refresh(refreshing, label: "Refreshing…")` — place it
  # directly above the scrollable content; the app flips `refreshing`
  # to start/stop the spinner strip (the trigger wiring is the
  # documented v1 hook point — see the class header).
  def pull_to_refresh(refreshing : Bool, id : String? = nil,
                      label : String? = nil) : Response
    add(PullToRefresh.new(refreshing, id: id, label: label))
  end
end
