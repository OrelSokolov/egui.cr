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

    # The control-accent variant AppKit paints on SELECTION surfaces
    # (checkbox fill, radio dot, switch track, selected segment) —
    # measured (0,119,249) on the oracle sheets; push buttons and
    # progress fills keep the brighter ACCENT (0,122,255).
    SELECTION = Color32.rgb(0, 119, 249)

    def self.light : Theme
      theme = DefaultTheme.build("macos", dark: false) do |v|
        v.panel_fill = Color32.rgb(236, 236, 236) # windowBackgroundColor
        v.text_color = Color32.rgb(6, 6, 6)       # labelColor
        v.window_fill = Color32.rgb(246, 246, 246)
        # Native titlebars sit a step DARKER than the window body
        # (#E9E9E9 — WindowFrame::Macos BG_BOTTOM, measured off the
        # oracle), so the caption reads as its own band instead of
        # blending into the content.
        v.title_bar_fill = Color32.rgb(233, 233, 233)
        v.window_stroke = Color32.rgb(209, 209, 209)
        # Shared bezel: popups, segmented container, progress track
        # (buttons/text fields override through their class rules).
        v.button_weak = Color32.rgb(218, 218, 218)
        v.button_hovered = Color32.rgb(208, 208, 208)
        v.button_active = Color32.rgb(185, 185, 185)
        v.button_stroke = Color32.rgb(209, 209, 209)
        v.selection_fill = ACCENT
        # Text selections paint their own pale blue (#BED4F9); input
        # focus rings a stronger one (#8CA9F5) — see TextEdit/Textarea.
        v.text_selection_fill = Color32.rgb(190, 212, 249)
        v.focus_ring_fill = Color32.rgb(140, 169, 245)
        # Menu/context-menu hover bands ride the text-selection tint
        # (native NSMenu highlight; black label text stays readable).
        v.menu_highlight_fill = Color32.rgb(190, 212, 249)
      end

      style = theme.style
      style.font_size = 13.0 # system font size
      # Window titles run one step up from the 13pt body (14pt) in a
      # 28pt caption (the default title_padding); the title band and
      # centering come from the shared defaults — only the exact
      # #E9E9E9 (WindowFrame::Macos BG_BOTTOM, measured off the
      # oracle) is pinned here against this theme's #F6F6F6 body.
      style.title_font_size = 14.0
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
        "box_fill"    => SELECTION,
        "check_color" => Color32.rgb(255, 255, 255),
      })
      sheet.rule("radio:selected", StyleVars{
        "dot_fill" => SELECTION,
      })

      # Switches (ToggleButton): 54x24 capsule track with a rim; the
      # knob is a 30x20 capsule (default knob_rounding), +3 off the
      # track ends (oracle/macos/png/switch.png). Gray track lerps to
      # accent (selection_fill) when on.
      sheet.rule("toggle_button", StyleVars{
        "sync_with_text" => false,
        "tumbler_size"   => 24.0,
        "track_width"    => 54.0,
        "knob_width"     => 30.0,
        "knob_color"     => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(214, 214, 214),
        "track_fill"     => Color32.rgb(213, 213, 213),
        "selection_fill" => SELECTION,
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
      # The focused field carries a ~3pt accent ring riding OUTSIDE
      # the bezel (native NSTextField focus) — the widget paints it on
      # an expanded rect before the box; the bezel itself never grows
      # or recolors.

      # A search field (a TextEdit under the "search" style scope —
      # see Ui#with_style_scope) is a CAPSULE: NSSearchStyle rounds to
      # the full pill (`border-radius: 9999px`; the "capsule" keyword
      # names the min(w,h)/2 limit), while plain text fields keep the
      # 6pt corners above.
      sheet.rule("search.text_edit", StyleVars{
        "rounding" => "capsule",
      })

      # Progress: 9pt thin capsule track (semicircle ends at any
      # width — the "capsule" rounding keyword), accent fill,
      # track-colored stroke (no visible border — macOS has none).
      sheet.rule("progressbar", StyleVars{
        "width"          => 200.0,
        "height"         => 9.0,
        "rounding"       => "capsule",
        "selection_fill" => ACCENT,
        "stroke"         => Color32.rgb(222, 222, 222),
      })

      # Slider: white circular thumb (selection_fill slot on Slider is
      # the handle), #B7B7B7 rail with a blue accent fill from the left
      # end up to the thumb (#007AFF), fixed 220pt length, 18pt thumb.
      sheet.rule("slider", StyleVars{
        "width"          => 220.0,
        "handle_size"    => 9.0,
        "selection_fill" => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(183, 183, 183),
        "fill"           => ACCENT,
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
        "selection_fill" => SELECTION,
      })

      theme
    end

    # The accent "default" push button (macOS key-equivalent \r look):
    # blue bezel, white label. The inline `#style` alone survives every
    # state — the cascade contract puts inline ABOVE class rules
    # (inline beats `:hover`, CSS `style="…"` semantics), so no
    # per-element pinning is needed.
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
