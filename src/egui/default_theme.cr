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
#     StyleVars{"background" => Color32.rgb(255, 140, 0)})
#
#   # 2. derive a whole theme from the defaults:
#   theme = DefaultTheme.dark
#   theme.style.visuals.selection_fill = Color32.rgb(255, 140, 0)
#   theme.sheet.rule("button:hover", StyleVars{"background" => Color32.rgb(120, 40, 40)})
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

    # Same, but with a custom palette: the block runs on the fresh
    # theme's Visuals BETWEEN the base palette and the element rules,
    # so the class rules (button/sidebar/tabs) are derived from the
    # custom colors too — the way to build whole presets:
    #
    #   DefaultTheme.build("winxp", dark: false) do |v|
    #     v.window_fill = Color32.rgb(236, 233, 216)
    #     v.selection_fill = Color32.rgb(49, 106, 197)
    #   end
    def self.build(name : String, *, dark : Bool, &palette : Visuals -> Nil) : Theme
      theme = Theme.new(name, dark)
      base_style(theme, dark)
      yield theme.style.visuals
      element_rules(theme)
      theme
    end

    # --- base palette (what un-classed widgets read via `ctx.style`) ---

    private def self.base_style(theme : Theme, dark : Bool) : Nil
      v = theme.style.visuals
      v.dark = dark
      v.interact_cursor = CursorIcon::Pointer

      if dark
        v.window_fill = Color32.rgba(27, 27, 30, 255)
        v.window_stroke = Color32.rgba(80, 80, 80, 255)
        v.title_bar_fill = v.window_fill
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
        v.modal_dim = Color32.rgba(0, 0, 0, 100)
      else
        v.window_fill = Color32.rgba(252, 252, 252, 255)
        v.window_stroke = Color32.rgba(190, 190, 190, 255)
        v.title_bar_fill = v.window_fill
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
      sheet.rule("sidebar.tab:hover", StyleVars{"background" => v.button_weak})
      sheet.rule("sidebar.tab:selected", StyleVars{
        "background" => v.selection_fill,
        "text_color" => Color32.rgba(240, 240, 240, 255),
      })

      # tabs — horizontal top tab strip
      sheet.rule("tabs", StyleVars{"tab_spacing" => 0.0})
      sheet.rule("tabs.tab", StyleVars{
        "padding.top"    => 6.0,
        "padding.right"  => 12.0,
        "padding.bottom" => 6.0,
        "padding.left"   => 12.0,
        "text_color"     => v.fade_color(v.text_color),
      })
      sheet.rule("tabs.tab:hover", StyleVars{
        "background" => v.button_weak,
        "text_color" => v.text_color,
      })
      sheet.rule("tabs.tab:selected", StyleVars{
        "background"         => v.button_hovered,
        "text_color"      => v.text_color,
        "underline_color" => v.selection_fill,
        "underline_width" => 2.0,
      })

      # button
      sheet.rule("button", StyleVars{
        "background"         => v.button_weak,
        "text_color"      => v.text_color,
        "padding.top"     => 4.0,
        "padding.right"   => 8.0,
        "padding.bottom"  => 4.0,
        "padding.left"    => 8.0,
      })
      sheet.rule("button:hover", StyleVars{"background" => v.button_hovered})
      sheet.rule("button:active", StyleVars{"background" => v.button_active})

      # link — `ui.hyperlink` / `ui.hyperlink_to` (HTML <a>: colored,
      # underlined text by default). The `:hover`/`:active` overlays
      # recolor the text the way button states recolor the fill;
      # `underline` is the CSS `text-decoration` (a `link:hover {
      # underline }` rule can re-enable it per state).
      sheet.rule("link", StyleVars{
        "text_color" => v.hyperlink_color,
        "underline"  => true,
      })
      sheet.rule("link:hover", StyleVars{
        "text_color" => v.strong_color(v.hyperlink_color),
      })
      sheet.rule("link:active", StyleVars{
        "text_color" => v.fade_color(v.hyperlink_color, 0.8),
      })
    end
  end
end
