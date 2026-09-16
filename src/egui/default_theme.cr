# The complete default theme of egui.cr — the "user-agent stylesheet".
# Every built-in element's default styles live in THIS file and only
# here: the base `Style` (palette, spacing) per preset plus the
# `StyleSheet` class rules for the elements styled through classes
# (`sidebar.*`, `button.*`, … — widgets adopt classes gradually,
# `Widget#style_class` is the hook).
#
# Class rules set only what DIFFERS from the base Style; everything
# else inherits (font size, panel colors, …) so tweaking the base
# still reaches every element.
#
# Developers customize ON TOP of the defaults, two ways:
#
#   # 1. live, CSS-like — tweak classes of the active theme:
#   ctx.stylesheet.rule("sidebar.tab:selected",
#     StyleVars{"fill" => Color32.rgb(255, 140, 0)})
#
#   # 2. derive a whole theme from the defaults:
#   theme = DefaultTheme.dark
#   theme.style.visuals.selection_fill = Color32.rgb(255, 140, 0)
#   theme.sheet.rule("button:hover", StyleVars{"fill" => Color32.rgb(120, 40, 40)})
#   ctx.theme = theme

module Egui
  module DefaultTheme
    def self.dark : Theme
      build("dark", dark: true)
    end

    def self.light : Theme
      build("light", dark: false)
    end

    # Assemble a full theme from the defaults below. Public so apps can
    # derive custom presets (`build("ocean", dark: false)` + tweaks).
    def self.build(name : String, *, dark : Bool) : Theme
      theme = Theme.new(name, dark)
      base_style(theme, dark)
      element_rules(theme)
      theme
    end

    # --- base palette (what un-classed widgets read via `ctx.style`) ---

    private def self.base_style(theme : Theme, dark : Bool) : Nil
      v = theme.style.visuals
      v.dark = dark
      v.interact_cursor = CursorIcon::Pointer

      if dark
        v.window_fill = Color32.rgba(27, 27, 30, 235)
        v.window_stroke = Color32.rgba(80, 80, 80, 255)
        v.panel_fill = Color32.rgba(22, 22, 24, 255)
        v.text_color = Color32.rgba(235, 235, 235, 255)
        v.title_color = Color32.rgba(250, 250, 250, 255)
        v.button_weak = Color32.rgba(60, 60, 60, 180)
        v.button_hovered = Color32.rgba(85, 85, 85, 200)
        v.button_active = Color32.rgba(110, 110, 110, 220)
        v.border_color = Color32.rgba(96, 96, 96, 255)
        v.selection_fill = Color32.rgba(0, 122, 204, 255)
        v.hyperlink_color = Color32.rgba(102, 170, 255, 255)
        v.separator_color = Color32.rgba(90, 90, 90, 255)
        v.modal_dim = Color32.rgba(0, 0, 0, 140)
      else
        v.window_fill = Color32.rgba(252, 252, 252, 245)
        v.window_stroke = Color32.rgba(190, 190, 190, 255)
        v.panel_fill = Color32.rgba(243, 243, 243, 255)
        v.text_color = Color32.rgba(35, 35, 35, 255)
        v.title_color = Color32.rgba(15, 15, 15, 255)
        v.button_weak = Color32.rgba(228, 228, 228, 255)
        v.button_hovered = Color32.rgba(209, 209, 209, 255)
        v.button_active = Color32.rgba(185, 185, 185, 255)
        v.border_color = Color32.rgba(160, 160, 160, 255)
        v.selection_fill = Color32.rgba(0, 122, 204, 255)
        v.hyperlink_color = Color32.rgba(0, 92, 170, 255)
        v.separator_color = Color32.rgba(200, 200, 200, 255)
        v.modal_dim = Color32.rgba(0, 0, 0, 70)
      end
    end

    # --- element class rules (the default stylesheet) ---
    #
    # Keys follow the CSS-like conventions: per-side boxes
    # (`padding.top/left/…`), state overlays (`button:hover`, …).
    # Colors are taken from the theme's Visuals so presets stay
    # palette-correct; consumption falls back to Visuals/Spacing for
    # anything left unset.

    private def self.element_rules(theme : Theme) : Nil
      sheet = theme.sheet
      v = theme.style.visuals

      # sidebar — navigation sections + tabs
      sheet.rule("sidebar", StyleVars{"tab_spacing" => 0.0})
      sheet.rule("sidebar.section", StyleVars{
        "font_size"  => 13.0,
        "margin.top" => 14.0,
        "margin.left" => 4.0,
        "text_color" => v.fade_color(v.text_color),
      })
      sheet.rule("sidebar.tab", StyleVars{
        "padding.top"    => 6.0,
        "padding.right"  => 12.0,
        "padding.bottom" => 6.0,
        "padding.left"   => 12.0,
        "text_color"     => v.text_color,
      })
      sheet.rule("sidebar.tab:hover", StyleVars{"fill" => v.button_weak})
      sheet.rule("sidebar.tab:selected", StyleVars{
        "fill"       => v.selection_fill,
        "text_color" => Color32.rgba(240, 240, 240, 255),
      })

      # button — GTK-proportioned default padding (taller buttons)
      sheet.rule("button", StyleVars{
        "fill"            => v.button_weak,
        "text_color"      => v.text_color,
        "padding.top"     => 8.0,
        "padding.right"   => 14.0,
        "padding.bottom"  => 8.0,
        "padding.left"    => 14.0,
      })
      sheet.rule("button:hover", StyleVars{"fill" => v.button_hovered})
      sheet.rule("button:active", StyleVars{"fill" => v.button_active})
    end
  end
end
