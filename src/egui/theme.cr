# Global theming (a thin layer over the upstream `Style` port).
#
# `Theme` bundles a `Style` (spacing + visuals + font size) and a
# `StyleSheet` (CSS-like element classes) under a name. All default
# values — palette AND element class rules — live in `default_theme.cr`
# (`DefaultTheme`); the presets below are just aliases into it. The
# active theme lives on the `Context` (`ctx.theme`) — assigning
# `ctx.theme = Theme.light` swaps it instantly: immediate-mode widgets
# re-read the theme style every frame, so the whole UI repaints with
# the new palette on the next frame.
#
# `WidgetStyle` is the per-widget override layer: every field is nilable,
# nil meaning "inherit from the theme". `WidgetStyle#merge_over(base)`
# clones the theme's Style and copies the non-nil fields in, producing
# the widget's effective style (see `Widget#style` / `#effective_style`).

module Egui
  class Theme
    getter name : String
    getter? dark : Bool
    getter style : Style
    # CSS-like class styles for this theme (see `StyleSheet`) — swaps
    # together with the palette on `ctx.theme = …`.
    getter sheet : StyleSheet

    def initialize(@name : String, @dark : Bool, @style : Style = Style.new)
      @sheet = StyleSheet.new
    end

    # The default presets, assembled from the full defaults in
    # `default_theme.cr` (base palette + element class rules).
    def self.dark : Theme
      DefaultTheme.dark
    end

    def self.light : Theme
      DefaultTheme.light
    end

    def to_s(io : IO) : Nil
      io << "Theme(" << @name << ")"
    end
  end

  # Per-widget style overrides. All fields are nilable; `nil` means
  # "take the value from the app theme". `#merge_over` applies the
  # non-nil fields onto a copy of the theme's Style:
  #
  #   ui.add(Egui::Button.new("OK").style do |s|
  #     s.fill = Egui::Color32.rgb(180, 40, 40)
  #     s.text_color = Egui::Color32.rgb(255, 255, 255)
  #   end)
  #
  # An overridden widget keeps its overrides when the theme is swapped;
  # every field left nil follows the new theme automatically.
  class WidgetStyle
    property text_color : Color32?
    # Button idle / hovered / active fills (upstream `WidgetVisuals`
    # weak/hovered/active — see `Visuals#button_fill`).
    property fill : Color32?
    property fill_hovered : Color32?
    property fill_active : Color32?
    property stroke : Color32?
    # Accent: progress bar fill, slider handle, selection.
    property selection_fill : Color32?
    property separator_color : Color32?
    property hyperlink_color : Color32?
    property font_size : Float64?
    property button_padding : Vec2?

    def initialize
      @text_color = nil
      @fill = nil
      @fill_hovered = nil
      @fill_active = nil
      @stroke = nil
      @selection_fill = nil
      @separator_color = nil
      @hyperlink_color = nil
      @font_size = nil
      @button_padding = nil
    end

    # Effective style = the theme's Style with every non-nil override
    # applied. Returns a copy; the theme is never mutated.
    def merge_over(base : Style) : Style
      merged = base.clone
      v = merged.visuals
      if (c = @text_color)
        v.text_color = c
      end
      if (c = @fill)
        v.button_weak = c
      end
      if (c = @fill_hovered)
        v.button_hovered = c
      end
      if (c = @fill_active)
        v.button_active = c
      end
      if (c = @stroke)
        v.button_stroke = c
      end
      if (c = @selection_fill)
        v.selection_fill = c
      end
      if (c = @separator_color)
        v.separator_color = c
      end
      if (c = @hyperlink_color)
        v.hyperlink_color = c
      end
      if (c = @font_size)
        merged.font_size = c
      end
      if (c = @button_padding)
        merged.spacing.button_padding = c
      end
      merged
    end
  end
end
