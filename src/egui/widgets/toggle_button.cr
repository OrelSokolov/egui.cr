# A switch-style toggle (egui has none in-tree; this is the egui.cr
# extra the ecosystem keeps asking for — see ToggleSwitch discussions).
#
# Semantically a Checkbox (reads `checked`, reports the flip through
# `Response#changed?`), but painted as an iOS-style track + knob, which
# reads better for instantaneous settings than a checkbox does.
#
# The flip itself is instantaneous in the app's state, but the paint
# eases over ~150 ms (`Context#animate_value_with_time`, keyed by the
# widget id): the knob slides along the track and the track fill
# cross-fades between button_stroke and selection_fill.
#
# Sizing: by default the tumbler matches the text height
# (`sync_with_text` = true). Untie it (`sync_with_text => false`) and
# `tumbler_size` (the knob/track height; the track stays 2x as wide)
# takes over:
#
#   ctx.stylesheet.rule("toggle_button", StyleVars{
#     "sync_with_text" => false,
#     "tumbler_size"   => 20.0,
#   })

module Egui
  class ToggleButton
    include Widget

    def initialize(@checked : Bool, @text : String? = nil, id : String? = nil)
      @id_name = id
    end

    def style_class : String?
      "toggle_button"
    end

    def style_properties : Array(StyleProp)
      StyleProps.textlike + [
        StyleProp.new("selection_fill", :color, label: "fill (on)"),
        StyleProp.new("stroke", :color, label: "track stroke"),
        StyleProp.new("sync_with_text", :bool, fallback: true),
        StyleProp.new("tumbler_size", :number),
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
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, style.font_weight, false)
      text_size = @text ? fonts.measure(@text.not_nil!, font_size) : Vec2.zero
      class_vars = style_vars(ui, id, "toggle_button")

      # Sizing: synced (default) the tumbler rides the text height (the
      # icon width when there is no text); unsynced, tumbler_size wins.
      icon = style.spacing.icon_width
      text_h = @text ? text_size.y : 0.0
      if class_vars.bool("sync_with_text", true)
        tumbler_h = text_h > 0.0 ? text_h : icon
      else
        tumbler_h = class_vars.f64("tumbler_size", icon)
      end
      knob = tumbler_h
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
      # `anim_t` eases 0→1 across the flip, driving both the fill
      # cross-fade and the knob position below.
      anim_t = ui.ctx.animate_value_with_time(id, @checked ? 1.0 : 0.0, 0.15)
      track_fill = visuals.button_stroke.lerp(visuals.selection_fill, anim_t)
      track_fill = visuals.button_active if response.active? && @checked
      ui.painter.rect(track, track_h / 2.0, track_fill)

      # Knob slides between the track's ends; a hair of inset so it
      # never touches the rounded ends.
      inset = 2.0
      travel = track_w - knob - 2.0 * inset
      knob_x = track.left + inset + anim_t * travel
      ui.painter.circle(Pos2.new(knob_x + knob / 2.0, track.center.y),
        knob / 2.0 - inset / 2.0, visuals.text_color)

      if (text = @text)
        ui.painter.text(
          Pos2.new(track.right + style.spacing.icon_spacing, rect.center.y),
          text, font_size, visuals.text_color, family: face_family,
          bold: face_bold)
      end

      response.paint_focus_ring(track_h / 2.0)
      response.mark_changed if response.clicked?
      response
    end
  end
end
