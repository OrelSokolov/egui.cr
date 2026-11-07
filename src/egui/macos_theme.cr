# macOS platform theme — egui.cr painted like native AppKit (light
# aqua, multicolor accent). Values measured from the oracle sheets
# (oracle/macos/png — see oracle/FINDINGS.md): 24pt controls, #007AFF
# accent on state (checkbox/switch/progress/segment), #DADADA buttons,
# white 26pt text fields with a gray border, thin slider/progress
# tracks, 13pt system text.
#
#   app.theme = Egui::MacOsTheme.light
#
# Default-button look (the accent-filled "OK"): use MacOsTheme.button
# helper — WidgetStyle has no class layer for a "default" variant yet.

require "./default_theme"

module Egui
  module MacOsTheme
    # systemBlue (multicolor accent), sRGB.
    ACCENT = Color32.rgb(0, 122, 255)

    def self.light : Theme
      theme = DefaultTheme.build("macos", dark: false) do |v|
        v.panel_fill = Color32.rgb(236, 236, 236) # windowBackgroundColor
        v.text_color = Color32.rgb(6, 6, 6)       # labelColor
        v.window_fill = Color32.rgb(246, 246, 246)
        v.window_stroke = Color32.rgb(209, 209, 209)
        # Shared bezel: popups, segmented container, progress track
        # (buttons/text fields override through their class rules).
        v.button_weak = Color32.rgb(218, 218, 218)
        v.button_hovered = Color32.rgb(208, 208, 208)
        v.button_active = Color32.rgb(185, 185, 185)
        v.button_stroke = Color32.rgb(209, 209, 209)
        v.selection_fill = ACCENT
      end

      style = theme.style
      style.font_size = 13.0 # system font size
      sp = style.spacing
      sp.icon_width = 16.0        # checkbox/radio box
      sp.icon_width_inner = 7.0   # radio dot
      sp.slider_rail_width = 4.0  # thin macOS rail
      # 26pt text fields: line ~15 + 2*(3.5+2) inset. The y floor is
      # the field's height floor too (max(line, interact.y) + inset).
      sp.button_padding = Vec2.new(12.0, 3.5)
      sp.interact_size = Vec2.new(40.0, 15.0)

      sheet = theme.sheet

      # Push buttons: 24pt tall (#DADADA bezel, ~6pt rounding), roomy
      # horizontal padding.
      sheet.rule("button", StyleVars{
        "padding.top"    => 4.0,
        "padding.bottom" => 4.0,
        "padding.left"   => 12.0,
        "padding.right"  => 12.0,
        "rounding"       => 6.0,
        "background"     => Color32.rgb(218, 218, 218),
        "stroke"         => Color32.rgb(199, 199, 199),
      })
      sheet.rule("button:hover", StyleVars{
        "background" => Color32.rgb(208, 208, 208),
      })
      sheet.rule("button:active", StyleVars{
        "background" => Color32.rgb(185, 185, 185),
      })
      # The default theme ships touch-media button metrics (14/16
      # padding, 15pt font — the 44pt target). A macOS look keeps the
      # 24pt bezel at any width: re-declare the media rule with the
      # desktop metrics so narrow viewports don't grow the buttons.
      sheet.rule("button", StyleVars{
        "padding.top"    => 4.5,
        "padding.bottom" => 4.5,
        "padding.left"   => 12.0,
        "padding.right"  => 12.0,
        "font_size"      => 13.0,
        "rounding"       => 6.0,
        "background"     => Color32.rgb(218, 218, 218),
        "stroke"         => Color32.rgb(199, 199, 199),
      }, media: DefaultTheme::MOBILE_MAX)

      # Checkboxes/radios: white 16pt box, gray ring; checked state
      # fills with the accent + a white mark (the checkbox:checked /
      # radio:selected rule layers added for this).
      sheet.rule("checkbox", StyleVars{
        "box_fill"    => Color32.rgb(255, 255, 255),
        "box_stroke"  => Color32.rgb(208, 208, 208),
        "check_width" => 2.4,
        "rounding"    => 3.5,
      })
      sheet.rule("checkbox:checked", StyleVars{
        "box_fill"    => ACCENT,
        "check_color" => Color32.rgb(255, 255, 255),
      })
      sheet.rule("radio:selected", StyleVars{
        "dot_fill" => ACCENT,
      })

      # Switches (ToggleButton): 54x24 capsule with a rim, white knob
      # with a hair of its own stroke, gray track lerping to accent
      # (selection_fill) when on.
      sheet.rule("toggle_button", StyleVars{
        "sync_with_text" => false,
        "tumbler_size"   => 24.0,
        "track_width"    => 54.0,
        "knob_color"     => Color32.rgb(255, 255, 255),
        "knob_stroke"    => Color32.rgb(226, 226, 226),
        "stroke"         => Color32.rgb(198, 198, 198),
        "selection_fill" => ACCENT,
      })

      # Text fields/search: white 26pt box, gray border, 6pt rounding,
      # tight ~8pt text inset.
      sheet.rule("text_edit", StyleVars{
        "fill"           => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(214, 214, 214),
        "rounding"       => 6.0,
        "padding.top"    => 2.0,
        "padding.bottom" => 2.0,
        "padding.left"   => 6.0,
        "padding.right"  => 6.0,
      })

      # Progress: 9pt thin track, accent fill, track-colored stroke
      # (no visible border — macOS has none).
      sheet.rule("progressbar", StyleVars{
        "width"          => 200.0,
        "height"         => 9.0,
        "selection_fill" => ACCENT,
        "stroke"         => Color32.rgb(222, 222, 222),
      })

      # Slider: white circular thumb (selection_fill slot on Slider is
      # the handle), #B7B7B7 rail, fixed 220pt length, 18pt thumb.
      sheet.rule("slider", StyleVars{
        "width"          => 220.0,
        "handle_size"    => 9.0,
        "selection_fill" => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(183, 183, 183),
      })

      # Segmented control: one #DADADA capsule, even ~73pt cells
      # (matches the native 220x24 control), accent selected segment
      # with white text.
      sheet.rule("segmented", StyleVars{
        "padding.left"   => 19.5,
        "padding.right"  => 19.5,
        "padding.top"    => 4.0,
        "padding.bottom" => 4.0,
        "rounding"       => 6.0,
        "background"     => Color32.rgb(218, 218, 218),
        "selection_fill" => ACCENT,
      })

      theme
    end

    # The accent "default" push button (macOS key-equivalent \r look):
    # blue bezel, white label.
    def self.default_button(ui : Ui, text : String,
                            id : String? = nil) : Response
      btn = Button.new(text, id: id)
      btn.style do |s|
        s.background = ACCENT
        s.text_color = Color32.rgb(255, 255, 255)
        s.stroke = ACCENT
      end
      ui.add(btn)
    end
  end
end
