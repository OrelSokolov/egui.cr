# Mobile switch (Material 3 `Switch` / iOS toggle) — the Phase 1
# reference for plans/todo/mobile_widgets.md.
#
# ToggleButton already paints a capsule + knob (macOS NSSwitch look);
# the mobile variant differs in geometry and color contract: a wider
# 52×32 track, a thumb that GROWS when on (Material: 16 off → 24 on)
# and a filled track in the selection color when on (no rim). Tap
# only — mobile switches don't drag.
#
# Semantically a Checkbox: reads `checked`, reports the flip through
# `Response#changed?`. The knob position/thumb size ease over ~150 ms
# (`Context#animate_value_with_time`, keyed by the widget id).
#
# Styling — the `switch` class: `on_color` (track when on; default
# selection_fill), `off_color` (track when off), `thumb_color`,
# `track_width` (52), `tumbler_size` (32), `thumb_ratio` (0.75 → the
# off thumb is 75% of the track height; the on thumb fills it).

module Egui
  class Switch
    include Widget

    def initialize(@checked : Bool, id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "switch"
    end

    def style_properties : Array(StyleProp)
      [
        StyleProp.new("on_color", :color),
        StyleProp.new("off_color", :color),
        StyleProp.new("thumb_color", :color),
        StyleProp.new("track_width", :number, min: 0.0),
        StyleProp.new("tumbler_size", :number, min: 0.0),
        StyleProp.new("thumb_ratio", :number, min: 0.0, fallback: 0.75),
      ]
    end

    def inspector_label : String?
      @checked ? "on" : "off"
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      visuals = style.visuals
      class_vars = style_vars(ui, id)

      track_h = class_vars.f64("tumbler_size", 32.0)
      track_w = class_vars.f64("track_width", 52.0)
      size = styled_size(Vec2.new(track_w, track_h), class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      anim_t = ui.ctx.animate_value_with_time(id, @checked ? 1.0 : 0.0, 0.15)

      # Track: filled gray when off, selection (accent) when on — the
      # cross-fade rides the same anim_t as the thumb.
      on_color = class_vars.color("on_color", visuals.selection_fill)
      off_color = class_vars.color("off_color", visuals.separator_color)
      track_fill = off_color.lerp(on_color, anim_t)
      ui.painter.capsule(rect, track_fill)

      # Thumb: grows from thumb_ratio (0.75) of the track height when
      # off to a full-diameter disc when on, with the Material 2pt
      # inset at the ends.
      thumb_off = track_h * class_vars.f64("thumb_ratio", 0.75)
      thumb_d = thumb_off + (track_h - 4.0 - thumb_off) * anim_t
      inset = 2.0 + (track_h - thumb_d) / 2.0
      travel = track_w - thumb_d - 2.0 * inset
      thumb_x = rect.left + inset + anim_t * travel
      thumb_rect = Rect.from_min_size(
        Pos2.new(thumb_x, rect.center.y - thumb_d / 2.0),
        Vec2.new(thumb_d, thumb_d))
      ui.painter.circle(thumb_rect.center, thumb_d / 2.0,
        class_vars.color("thumb_color", visuals.text_color), nil)

      response.paint_focus_ring(track_h / 2.0)
      response.mark_changed if response.clicked?
      response
    end
  end
end

# Ui sugar for the mobile widget set. Each phase file appends its own
# helpers here (the class is reopened per file — the shared `ui.cr`
# stays untouched by the mobile plan).
class Egui::Ui
  # `ui.switch(checked) { |on| state = on }` — the block fires with
  # the NEW value on toggle; `Response#changed?` reports the same.
  def switch(checked : Bool, id : String? = nil,
             &on_change : Bool ->) : Response
    response = add(Switch.new(checked, id: id))
    on_change.call(!checked) if response.changed?
    response
  end

  def switch(checked : Bool, id : String? = nil) : Response
    add(Switch.new(checked, id: id))
  end

  # Reactive form: `ui.switch(sig)`.
  def switch(sig : Signal(Bool)) : Response
    signal_form add(Switch.new(sig.value)) do
      sig.value = !sig.value
    end
  end
end
