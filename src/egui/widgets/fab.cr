# Mobile FAB (Material 3 floating action button) — plans/todo/mobile_widgets.md #6.
#
# A round 56pt icon button with a drop shadow, meant to be PINNED over
# the screen content through `ui.overlay` — the plan's #6 note: the
# FAB floats above the body while the body keeps its own interaction.
# The widget itself is position-agnostic (it lays out at its natural
# size in the current flow); the overlay wiring is the app's:
#
#   ui.overlay(:bottom_right, margin: Egui::StyleBox.new(bottom: 16, right: 16),
#              id: "fab") do |o|
#     o.fab(:plus) { new_item }
#   end
#
# The shadow extends beyond the interact rect and carries NO hit
# target — taps landing on the shadow pass through to the body (the
# "does not steal clicks underneath" contract; the overlay's own
# pass_through flag additionally drops the overlay's background
# target). Tap target is the circle itself.
#
# The extended variant (icon + text) — `Fab.new(:plus, "New")` — grows
# into a capsule at the same height (Material keeps 56 for it too).
#
# Styling goes through the global `StyleSheet` (CSS-like classes):
#   fab — color (the fill; selection_fill by default), text_color
#         (icon + label glyph tint), size (56 — the diameter/height),
#         shadow_color, shadow_blur (12; 0 drops the shadow), font_size
#         (extended label), font_family + width/height/min_/max_
#         length keys via #styled_size
# The theme presets do NOT ship defaults for the class yet (the mobile
# theme catalog is a post-phase-2 decision) — the Visuals fallbacks
# above apply until a rule sets a key.

module Egui
  class Fab
    include Widget

    DEFAULT_SIZE = 56.0
    # The glyph inside the round variant scales with the diameter so a
    # style-driven `size` keeps the icon proportioned (24 at 56).
    GLYPH_RATIO = 24.0 / 56.0
    # Extended variant paddings: horizontal inset of the glyph/label,
    # and the gap between them.
    PAD_X = 20.0
    GAP   = 10.0

    def initialize(@icon : Symbol, @label : String? = nil,
                   id : String? = nil)
      unless Icons::NAMES.includes?(@icon)
        raise ArgumentError.new("Fab: unknown icon #{@icon.inspect} — " \
                                "Icons::NAMES has #{Icons::NAMES.inspect}")
      end
      @id_name = id
    end

    def style_class : String?
      "fab"
    end

    def style_properties : Array(StyleProp)
      [StyleProp.new("color", :color),
       StyleProp.new("text_color", :color),
       StyleProp.new("size", :number, min: 0.0),
       StyleProp.new("shadow_color", :color),
       StyleProp.new("shadow_blur", :number, min: 0.0),
       StyleProp.new("font_size", :number, min: 0.0),
       StyleProp.new("font_family", :string)]
    end

    def inspector_label : String?
      @label || @icon.to_s
    end

    def ui(ui : Ui) : Response
      id = resolve_id(ui)
      style = effective_style(ui, id)
      visuals = style.visuals
      vars = style_vars(ui, id)

      size = vars.f64("size", DEFAULT_SIZE)
      glyph = size * GLYPH_RATIO
      natural = if (label = @label)
        font_size = vars.f64("font_size", style.font_size)
        family = vars.str?("font_family")
        text_size = ui.ctx.fonts_for(family).measure(label, font_size)
        Vec2.new(PAD_X * 2.0 + glyph + GAP + text_size.x, size)
      else
        Vec2.new(size, size)
      end
      rect = ui.allocate_at_least(styled_size(natural, vars, ui, id))

      fill = vars.color("color", visuals.selection_fill)
      fg = vars.color("text_color", visuals.text_color)
      blur = vars.f64("shadow_blur", 12.0)
      shadow = vars.color?("shadow_color") || visuals.modal_dim
      rounding = rect.height / 2.0

      # Shadow FIRST (CSS paint order — it sits under the button), and
      # deliberately outside the interact below: no hit target on it.
      ui.painter.box_shadow(rect, shadow, blur, rounding) if blur > 0.0

      response = ui.interact(rect, id, Sense.click)
      # The circle/capsule ON TOP of the shadow — the tap target and
      # the visible button are exactly the same rect.
      ui.painter.rect(rect, rounding, fill)

      # Glyph centered in the round variant; leading the label in the
      # extended one (both vertically centered).
      if (label = @label)
        font_size = vars.f64("font_size", style.font_size)
        family = vars.str?("font_family")
        text_size = ui.ctx.fonts_for(family).measure(label, font_size)
        glyph_rect = Rect.from_min_size(
          Pos2.new(rect.min.x + PAD_X, rect.center.y - glyph / 2.0),
          Vec2.new(glyph, glyph))
        Icons.draw(ui.painter, @icon, glyph_rect, fg)
        ui.painter.text(
          Pos2.new(glyph_rect.max.x + GAP,
            rect.center.y - text_size.y / 2.0),
          label, font_size, fg, family: family)
      else
        glyph_rect = Rect.from_min_size(
          Pos2.new(rect.center.x - glyph / 2.0,
            rect.center.y - glyph / 2.0),
          Vec2.new(glyph, glyph))
        Icons.draw(ui.painter, @icon, glyph_rect, fg)
      end

      response.paint_focus_ring(rounding)
      response.mark_changed if response.clicked?
      response
    end
  end

  class Ui
    # `ui.fab(:plus) { create }` — the round FAB; the block fires on
    # click (also readable through `Response#clicked?`). `label:` turns
    # it into the extended icon+text variant.
    def fab(icon : Symbol, label : String? = nil, id : String? = nil,
            &on_click : ->) : Response
      response = add(Fab.new(icon, label, id: id))
      on_click.call if response.clicked?
      response
    end

    def fab(icon : Symbol, label : String? = nil,
            id : String? = nil) : Response
      add(Fab.new(icon, label, id: id))
    end
  end
end
