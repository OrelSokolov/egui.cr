# A switch-style toggle (egui has none in-tree; this is the egui.cr
# extra the ecosystem keeps asking for — see ToggleSwitch discussions).
#
# Semantically a Checkbox (reads `checked`, reports the flip through
# `Response#changed?`), but painted as an iOS-style track + knob, which
# reads better for instantaneous settings than a checkbox does.

module Egui
  class ToggleButton
    include Widget

    def initialize(@checked : Bool, @text : String? = nil, id : String? = nil)
      @id_name = id
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + [
        StyleProp.new("selection_fill", :color, label: "fill (on)"),
        StyleProp.new("stroke", :color, label: "track stroke"),
      ]
    end

    def inspector_label : String?
      @text
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      visuals = style.visuals
      font_size = style.font_size
      text_size = @text ? ui.ctx.fonts.measure(@text.not_nil!, font_size) : Vec2.zero

      knob = style.spacing.icon_width
      track_w = 2.0 * knob
      track_h = knob
      height = {track_h, text_size.y, style.spacing.interact_size.y * 0.7}.max
      total_w = track_w + (@text ? style.spacing.icon_spacing + text_size.x : 0.0)
      rect = ui.allocate_at_least(Vec2.new(total_w, height))
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      track = Rect.from_min_size(
        Pos2.new(rect.left, rect.center.y - track_h / 2.0),
        Vec2.new(track_w, track_h))
      # Unchecked track: button_stroke, not button_weak — light themes
      # set weak ≈ the panel fill (macOS #FFF on #FFF) and the track
      # has no border of its own to fall back on (cf. Slider's rail).
      track_fill = @checked ? visuals.selection_fill : visuals.button_stroke
      track_fill = visuals.button_active if response.active? && @checked
      ui.painter.rect(track, track_h / 2.0, track_fill)

      # Knob slides between the track's ends; a hair of inset so it
      # never touches the rounded ends.
      inset = 2.0
      travel = track_w - knob - 2.0 * inset
      knob_x = track.left + inset + (@checked ? travel : 0.0)
      ui.painter.circle(Pos2.new(knob_x + knob / 2.0, track.center.y),
        knob / 2.0 - inset / 2.0, visuals.text_color)

      if (text = @text)
        ui.painter.text(
          Pos2.new(track.right + style.spacing.icon_spacing, rect.center.y),
          text, font_size, visuals.text_color)
      end

      response.paint_focus_ring(track_h / 2.0)
      response.mark_changed if response.clicked?
      response
    end
  end
end
