# A switch-style toggle (egui has none in-tree; this is the egui.cr
# extra the ecosystem keeps asking for — see ToggleSwitch discussions).
#
# Semantically a Checkbox (reads `checked`, reports the flip through
# `Response#changed?`), but painted as a switch: a capsule track +
# a knob, which reads better for instantaneous settings than a
# checkbox does. The knob is a rounded rect (native NSSwitch paints
# 30×20 with ~7pt corners): by default `knob_rounding` is 9999 —
# clamped to half the short side it renders as a pill — and
# `knob_width` / `knob_rounding` class keys reshape it (macOS sets
# `knob_width` 30, see `MacOsTheme`).
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
      StyleProps.textlike + StyleProps.sizable + [
        StyleProp.new("selection_fill", :color, label: "fill (on)"),
        StyleProp.new("track_fill", :color, label: "fill (off)"),
        StyleProp.new("knob_color", :color),
        StyleProp.new("sync_with_text", :bool, fallback: true),
        StyleProp.new("tumbler_size", :number),
        StyleProp.new("track_width", :number),
        # The knob is a rounded rect (macOS NSSwitch: 30×20 with ~7pt
        # corners inside the 54×24 capsule track — see
        # oracle/macos/png/switch.png), not a disc. `knob_rounding`
        # defaults to 9999 — the CSS `border-radius: 9999px` pill
        # trick; the painter clamps it to half the knob's short side.
        StyleProp.new("knob_width", :number, min: 0.0),
        StyleProp.new("knob_rounding", :number, min: 0.0, fallback: 9999.0),
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
      class_vars = style_vars(ui, id)

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
      track_w = class_vars.f64("track_width", 2.0 * knob)
      track_h = knob
      height = {track_h, text_size.y, style.spacing.interact_size.y * 0.7}.max
      total_w = track_w + (@text ? style.spacing.icon_spacing + text_size.x : 0.0)
      size = styled_size(Vec2.new(total_w, height), class_vars, ui, id)
      rect = ui.allocate_at_least(size)
      response = ui.interact(rect, id, Sense.click | Sense::Focusable)

      track = Rect.from_min_size(
        Pos2.new(rect.left, rect.center.y - track_h / 2.0),
        Vec2.new(track_w, track_h))
      # Unchecked track defaults to button_stroke (light themes set
      # weak ≈ the panel fill — macOS #FFF on #FFF) unless the
      # `track_fill` rule key overrides it. `anim_t` eases 0→1 across
      # the flip, driving the fill cross-fade and the knob position
      # below. The track carries NO rim — themes that used to paint a
      # 1px border compensate by sizing the track itself a pixel up
      # (see MacOsTheme), which keeps the visual padding identical.
      anim_t = ui.ctx.animate_value_with_time(id, @checked ? 1.0 : 0.0, 0.15)
      track_fill = class_vars.color("track_fill", visuals.button_stroke)
        .lerp(visuals.selection_fill, anim_t)
      track_fill = visuals.button_active if response.active? && @checked
      ui.painter.capsule(track, track_fill)

      # Knob slides between the track's ends, 3pt off either end
      # (native: white 30×20 at x=+3, travel 18 inside the 54×24
      # track). The knob is a rounded RECT, not a disc — the default
      # 9999 rounding clamps to half the short side (pill; for the
      # default square knob that reads as the old circle).
      # Native NSSwitch casts the knob as a soft shadow onto the
      # track — a 1pt ring of the track fill slightly darkened just
      # above/below the knob (light theme gray 213→~200, accent
      # →~6% darker); left/right it fades to plain AA. A plain
      # same-rect stroke would also eat into the white and shrink
      # the knob (28×18 instead of 30×20), so the ring goes on an
      # EXPANDED rect, under the fill.
      inset = 3.0                  # end margin: native knob sits +3 off either end
      knob_h = track_h - 4.0       # 2pt vertical margin (native 24→20)
      knob_w = class_vars.f64("knob_width", knob_h)
      travel = track_w - knob_w - 2.0 * inset
      knob_x = track.left + inset + anim_t * travel
      knob_rect = Rect.from_min_size(
        Pos2.new(knob_x, track.center.y - knob_h / 2.0),
        Vec2.new(knob_w, knob_h))
      knob_rounding = class_vars.rounding_px("knob_rounding", knob_rect,
        9999.0)
      ui.painter.rect(knob_rect.expand(1.0), knob_rounding + 1.0,
        track_fill.mul_color(0.94))
      ui.painter.rect(knob_rect, knob_rounding,
        class_vars.color("knob_color", visuals.text_color))

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
