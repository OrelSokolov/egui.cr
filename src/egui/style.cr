# Port of egui_upstream/crates/egui/src/style.rs — trimmed to what
# slice-1 widgets read: spacing, font size, dark-theme widget colors.

module Egui
  class Spacing
    property item_spacing : Vec2
    property button_padding : Vec2
    property window_padding : Vec2
    property indent : Float64
    # Icon column width for checkbox/radio (upstream `Spacing`).
    property icon_width : Float64
    property icon_width_inner : Float64
    property icon_spacing : Float64
    # Minimum interactable widget size (upstream `Spacing::interact_size`).
    property interact_size : Vec2
    # Default slider track length (upstream `Spacing::slider_width`).
    property slider_width : Float64
    property slider_rail_width : Float64

    def initialize
      @item_spacing = Vec2.new(8.0, 6.0)
      @button_padding = Vec2.new(8.0, 4.0)
      @window_padding = Vec2.new(10.0, 8.0)
      @indent = 16.0
      @icon_width = 14.0
      @icon_width_inner = 8.0
      @icon_spacing = 6.0
      @interact_size = Vec2.new(40.0, 18.0)
      @slider_width = 100.0
      @slider_rail_width = 3.0
    end

    # Deep copy — every field is a value type (Vec2/Float64), so
    # field-by-field assignment is a full copy. Used by
    # `WidgetStyle#merge_over` so merged styles never alias the theme.
    def clone : Spacing
      other = Spacing.new
      other.item_spacing = item_spacing
      other.button_padding = button_padding
      other.window_padding = window_padding
      other.indent = indent
      other.icon_width = icon_width
      other.icon_width_inner = icon_width_inner
      other.icon_spacing = icon_spacing
      other.interact_size = interact_size
      other.slider_width = slider_width
      other.slider_rail_width = slider_rail_width
      other
    end
  end

  class Visuals
    property window_fill : Color32
    property window_stroke : Color32
    property panel_fill : Color32
    property text_color : Color32
    property title_color : Color32

    # Button states (egui `WidgetVisuals`): weak / hovered / active.
    property button_weak : Color32
    property button_hovered : Color32
    property button_active : Color32
    property button_stroke : Color32
    # Selection/accent fill (upstream `Visuals::selection.bg_fill`) —
    # progress bar fill, slider handle, hyperlinks.
    property selection_fill : Color32
    property hyperlink_color : Color32
    property separator_color : Color32
    # Scrim behind a modal dialog (`Context#modal`) — dim over the
    # layers below; light themes use a weaker one.
    property modal_dim : Color32
    # Which palette family this Visuals belongs to — drives #fade_color
    # (weaker variants darken on dark themes, lighten on light ones).
    # Set by the `Theme` presets.
    property dark : Bool
    # Cursor shown over hovered clickable widgets — the CSS
    # `cursor: pointer` style (upstream `Visuals::interact_cursor`,
    # which defaults to None there). Set to nil for the platform
    # default cursor.
    property interact_cursor : CursorIcon?

    def initialize
      @interact_cursor = CursorIcon::Pointer
      @dark = true
      @window_fill = Color32.rgba(27, 27, 30, 235)
      @window_stroke = Color32.rgba(80, 80, 80, 255)
      @panel_fill = Color32.rgba(22, 22, 24, 255)
      @text_color = Color32.rgba(235, 235, 235, 255)
      @title_color = Color32.rgba(250, 250, 250, 255)

      @button_weak = Color32.rgba(60, 60, 60, 180)
      @button_hovered = Color32.rgba(85, 85, 85, 200)
      @button_active = Color32.rgba(110, 110, 110, 220)
      @button_stroke = Color32.rgba(96, 96, 96, 255)
      @selection_fill = Color32.rgba(0, 122, 204, 255)
      @hyperlink_color = Color32.rgba(102, 170, 255, 255)
      @separator_color = Color32.rgba(90, 90, 90, 255)
      @modal_dim = Color32.rgba(0, 0, 0, 140)
    end

    # egui `Visuals::widget_visuals(interaction)` — pick by state.
    def button_fill(hovered : Bool, active : Bool) : Color32
      return @button_active if active
      return @button_hovered if hovered
      @button_weak
    end

    # egui `Visuals::fade_out_color`: a "weaker" variant of `color`.
    # Dark themes darken (gamma multiply), light themes lighten (blend
    # towards white) — so weak text/hints stay readable on both. The
    # hardcoded `mul_color(...)` calls inverted on light themes.
    def fade_color(color : Color32, factor : Float64 = 0.6) : Color32
      if @dark
        color.mul_color(factor)
      else
        t = 1.0 - factor
        Color32.rgba(
          (color.r.to_f + (255 - color.r) * t).round.to_u8,
          (color.g.to_f + (255 - color.g) * t).round.to_u8,
          (color.b.to_f + (255 - color.b) * t).round.to_u8,
          color.a)
      end
    end

    # Deep copy (all fields are value types) — see `Spacing#clone`.
    def clone : Visuals
      other = Visuals.new
      other.interact_cursor = interact_cursor
      other.window_fill = window_fill
      other.window_stroke = window_stroke
      other.panel_fill = panel_fill
      other.text_color = text_color
      other.title_color = title_color
      other.button_weak = button_weak
      other.button_hovered = button_hovered
      other.button_active = button_active
      other.button_stroke = button_stroke
      other.selection_fill = selection_fill
      other.hyperlink_color = hyperlink_color
      other.separator_color = separator_color
      other.modal_dim = modal_dim
      other.dark = dark
      other
    end
  end

  class Style
    property spacing : Spacing
    property visuals : Visuals
    property font_size : Float64
    # Wheel scroll speed in pixels per wheel notch. The sokol backend
    # reports ±1.0 per notch, so this multiplies the raw delta
    # (touchpads send small fractional deltas, scaled the same way).
    # Default 60 ≈ three text lines per notch. Tune per app:
    # `ctx.theme.style.scroll_speed = 100.0`.
    property scroll_speed : Float64

    def initialize
      @spacing = Spacing.new
      @visuals = Visuals.new
      @font_size = 16.0
      @scroll_speed = 60.0
    end

    # Deep copy: clones Spacing and Visuals, copies font_size. Used by
    # `WidgetStyle#merge_over` (theme style + widget overrides).
    def clone : Style
      other = Style.new
      other.spacing = spacing.clone
      other.visuals = visuals.clone
      other.font_size = font_size
      other.scroll_speed = scroll_speed
      other
    end
  end
end
