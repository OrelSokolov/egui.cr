# Port of egui_upstream/crates/egui/src/style.rs — trimmed to what
# slice-1 widgets read: spacing, font size, dark-theme widget colors.

module Egui
  class Spacing
    property item_spacing : Vec2
    # Padding setters clamp negatives to 0: this layout engine has no
    # "padding pulls content outside the widget" notion, so a negative
    # value only made text overflow its rect.
    getter button_padding : Vec2
    getter window_padding : Vec2

    def button_padding=(pad : Vec2) : Vec2
      @button_padding = Vec2.new({pad.x, 0.0}.max, {pad.y, 0.0}.max)
    end

    def window_padding=(pad : Vec2) : Vec2
      @window_padding = Vec2.new({pad.x, 0.0}.max, {pad.y, 0.0}.max)
    end
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
    # Title bar fill (`Context#window`'s drag strip) — defaults to
    # window_fill (a flat window); classic presets like Win95 paint a
    # navy bar with a white title.
    property title_bar_fill : Color32
    # Corner rounding of a floating window's frame.
    property window_rounding : Float64
    property panel_fill : Color32
    property text_color : Color32
    property title_color : Color32

    # Button states (egui `WidgetVisuals`): weak / hovered / active.
    property button_weak : Color32
    property button_hovered : Color32
    property button_active : Color32
    property button_stroke : Color32
    # Menu row highlight. Upstream egui reuses the button hover/active
    # visuals for it, but an app theme that flattens those to the panel
    # color (classic-look apps do) ends up with an invisible menu
    # selection — so a dedicated override exists. nil falls back to
    # button_hovered (hovered rows / bar entries) or button_active
    # (open bar entry); `menu_highlight_text` nil → text_color.
    property menu_highlight_fill : Color32?
    property menu_highlight_text : Color32?
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
      @window_fill = Color32.rgba(27, 27, 30, 255)
      @window_stroke = Color32.rgba(80, 80, 80, 255)
      @title_bar_fill = @window_fill
      @window_rounding = 6.0
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
      @modal_dim = Color32.rgba(0, 0, 0, 100)
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

    # The hover counterpart of #fade_color: a "stronger" variant of
    # `color` — dark themes lighten (blend towards white), light themes
    # darken, so a hovered accent (link color, …) reads stronger on
    # both, the way #fade_color reads weaker.
    def strong_color(color : Color32, factor : Float64 = 0.2) : Color32
      if @dark
        Color32.rgba(
          (color.r.to_f + (255 - color.r) * factor).round.to_u8,
          (color.g.to_f + (255 - color.g) * factor).round.to_u8,
          (color.b.to_f + (255 - color.b) * factor).round.to_u8,
          color.a)
      else
        color.mul_color(1.0 - factor)
      end
    end

    # Deep copy (all fields are value types) — see `Spacing#clone`.
    def clone : Visuals
      other = Visuals.new
      other.interact_cursor = interact_cursor
      other.window_fill = window_fill
      other.window_stroke = window_stroke
      other.title_bar_fill = title_bar_fill
      other.window_rounding = window_rounding
      other.panel_fill = panel_fill
      other.text_color = text_color
      other.title_color = title_color
      other.button_weak = button_weak
      other.button_hovered = button_hovered
      other.button_active = button_active
      other.button_stroke = button_stroke
      other.menu_highlight_fill = menu_highlight_fill
      other.menu_highlight_text = menu_highlight_text
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
    # Named font family (upstream `Style::override_font_id`'s family
    # half): a key into `Context#font_families` — nil = the primary
    # #fonts stack, "monospace" → #mono_font. Rides the style cascade
    # (theme → class rules → inline → inspector), so a rule like
    # `sheet.rule("terminal", StyleVars{"font_family" => "term"})`
    # swaps the font of a whole widget group.
    property font_family : String?
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
      @font_family = nil
      @scroll_speed = 60.0
    end

    # Deep copy: clones Spacing and Visuals, copies font_size. Used by
    # `WidgetStyle#merge_over` (theme style + widget overrides).
    def clone : Style
      other = Style.new
      other.spacing = spacing.clone
      other.visuals = visuals.clone
      other.font_size = font_size
      other.font_family = font_family
      other.scroll_speed = scroll_speed
      other
    end
  end
end
