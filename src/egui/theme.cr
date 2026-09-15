# Global theming (a thin layer over the upstream `Style` port).
#
# `Theme` bundles a `Style` (spacing + visuals + font size) under a name,
# with `Theme.dark` / `Theme.light` presets. The active theme lives on the
# `Context` (`ctx.theme`) — assigning `ctx.theme = Theme.light` swaps it
# instantly: immediate-mode widgets re-read the theme style every frame,
# so the whole UI repaints with the new palette on the next frame.
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

    def initialize(@name : String, @dark : Bool, @style : Style = Style.new)
    end

    # The default palette (the dark theme egui upstream ships). `Style`'s
    # `Visuals`/`Spacing` defaults *are* this palette; built explicitly
    # here so `Theme.dark` stays correct even if the class defaults move.
    def self.dark : Theme
      theme = new("dark", true)
      v = theme.style.visuals
      v.dark = true
      v.interact_cursor = CursorIcon::Pointer
      v.window_fill = Color32.rgba(27, 27, 30, 235)
      v.window_stroke = Color32.rgba(80, 80, 80, 255)
      v.panel_fill = Color32.rgba(22, 22, 24, 255)
      v.text_color = Color32.rgba(235, 235, 235, 255)
      v.title_color = Color32.rgba(250, 250, 250, 255)
      v.button_weak = Color32.rgba(60, 60, 60, 180)
      v.button_hovered = Color32.rgba(85, 85, 85, 200)
      v.button_active = Color32.rgba(110, 110, 110, 220)
      v.button_stroke = Color32.rgba(96, 96, 96, 255)
      v.selection_fill = Color32.rgba(0, 122, 204, 255)
      v.hyperlink_color = Color32.rgba(102, 170, 255, 255)
      v.separator_color = Color32.rgba(90, 90, 90, 255)
      v.modal_dim = Color32.rgba(0, 0, 0, 140)
      theme
    end

    # Light palette — same structure, inverted luminance. The accent
    # (`selection_fill`) is kept; the hyperlink darkens for contrast on
    # light panels.
    def self.light : Theme
      theme = new("light", false)
      v = theme.style.visuals
      v.dark = false
      v.interact_cursor = CursorIcon::Pointer
      v.window_fill = Color32.rgba(252, 252, 252, 245)
      v.window_stroke = Color32.rgba(190, 190, 190, 255)
      v.panel_fill = Color32.rgba(243, 243, 243, 255)
      v.text_color = Color32.rgba(35, 35, 35, 255)
      v.title_color = Color32.rgba(15, 15, 15, 255)
      v.button_weak = Color32.rgba(228, 228, 228, 255)
      v.button_hovered = Color32.rgba(209, 209, 209, 255)
      v.button_active = Color32.rgba(185, 185, 185, 255)
      v.button_stroke = Color32.rgba(160, 160, 160, 255)
      v.selection_fill = Color32.rgba(0, 122, 204, 255)
      v.hyperlink_color = Color32.rgba(0, 92, 170, 255)
      v.separator_color = Color32.rgba(200, 200, 200, 255)
      v.modal_dim = Color32.rgba(0, 0, 0, 70)
      theme
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
