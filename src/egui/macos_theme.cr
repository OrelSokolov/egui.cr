# macOS platform theme — egui.cr painted like native AppKit (light
# aqua, multicolor accent). Values measured from the oracle sheets
# (oracle/macos/png — see oracle/FINDINGS.md): 24pt controls, #007AFF
# accent on state (checkbox/switch/progress/segment), #DADADA buttons,
# white 26pt text fields with a gray border, thin slider/progress
# tracks, 13pt system text.
#
#   app.theme = Egui::MacOsTheme.light
#
# Default-button look (the accent-filled "OK"): use the
# MacOsTheme.default_button helper — WidgetStyle has no class layer
# for a "default" variant yet.

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

    # The pressed default-button bezel: AppKit darkens the accent
    # ~10% under the pointer press — measured (0,109,229) off a
    # highlighted native NSButtonCell (headless probe, the same
    # machinery as oracle/macos/render.swift).
    ACCENT_PRESSED = Color32.rgb(0, 109, 229)

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
        # NSColor.linkColor (light aqua) — measured (0,104,218) on the
        # oracle link sheet. AppKit text links are NOT underlined; the
        # twin sheets drop the underline via Hyperlink#underline(false).
        v.hyperlink_color = Color32.rgb(0, 104, 218)
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
      sp.icon_width_inner = 6.0   # radio dot (native white dot ~6px)
      sp.slider_rail_width = 5.0  # thin macOS rail (native bar: 6px incl. AA)
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

      # Checkboxes/radios: the UNCHECKED box is flat #D5D5D5 (the
      # native sheet shows no ring — a hard 1px edge to the background,
      # so stroke = fill); checked state fills with the accent + a
      # white mark (the checkbox:checked / radio:selected rule layers
      # added for this).
      sheet.rule("checkbox", StyleVars{
        "box_fill"    => Color32.rgb(213, 213, 213),
        "box_stroke"  => Color32.rgb(213, 213, 213),
        "check_width" => 2.4,
        "rounding"    => 3.5,
      })
      sheet.rule("checkbox:checked", StyleVars{
        "box_fill"    => SELECTION,
        "check_color" => Color32.rgb(255, 255, 255),
      })
      sheet.rule("radio", StyleVars{
        "ring_fill" => Color32.rgb(213, 213, 213),
      })
      sheet.rule("radio:selected", StyleVars{
        "ring_fill" => SELECTION,
        "dot_fill"  => Color32.rgb(255, 255, 255),
      })

      # Switches (ToggleButton): 55x25 capsule track, borderless — the
      # 1px the old rim occupied is spent on the track itself, so the
      # visual padding (knob 3pt off the ends, 2pt vertical) is
      # unchanged. The knob is a 30x21 capsule (default knob_rounding)
      # riding the taller track; gray fill lerps to accent
      # (selection_fill) when on (oracle/macos/png/switch.png).
      sheet.rule("toggle_button", StyleVars{
        "sync_with_text" => false,
        "tumbler_size"   => 25.0,
        "track_width"    => 55.0,
        "knob_width"     => 30.0,
        "knob_color"     => Color32.rgb(255, 255, 255),
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

      # Multiline text: NSTextView is a plain white box with NO bezel
      # and a tight ~6pt text inset (stroke = fill keeps the border
      # key from drawing a rim the native sheet has not).
      sheet.rule("textarea", StyleVars{
        "fill"           => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(255, 255, 255),
        # The layout hard-reserves 2pt of border inside the box plus
        # ~3pt of line leading before the glyphs — native starts its
        # first line 3pt from the box top (the y inset reads the
        # BOTTOM box side, the TextEdit idiom).
        "padding.top"    => 0.0,
        "padding.bottom" => -2.0,
        "padding.left"   => 4.0,
        "padding.right"  => 4.0,
      })

      # Color wells: the native swatch (NSColorWell sizeToFit) is
      # 48×24 with a hairline #D5D5D5 rim and ~4pt corners — the fill
      # is the color itself (ColorButton ignores any fill key).
      sheet.rule("color_well", StyleVars{
        "width"    => 48.0,
        "height"   => 24.0,
        "rounding" => 4.0,
        "stroke"   => Color32.rgb(213, 213, 213),
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

      # Stepper (NumberInput): NSStepper — the value sits straight on
      # the panel (transparent bezel: no fill, no border, no focus
      # recolor), only the spin column stands out as one flat #DADADA
      # bezel with constant arrows (no hover/press highlights).
      sheet.rule("number_input", StyleVars{
        "fill"        => Color32.transparent,
        "stroke"      => Color32.transparent,
        "rounding"    => 3.0,
        "button_fill" => Color32.rgb(218, 218, 218),
      })

      theme
    end

    # The accent "default" push button (macOS key-equivalent \r look):
    # blue bezel, white label. The colors are pinned per ELEMENT as
    # well: class state rules (`button:hover/:active`) sit ABOVE
    # inline styles in the cascade and would gray the bezel on
    # press — the element layer (`ctx.set_id_style`) outranks them,
    # so the accent + white text survive every state. The press still
    # SHOWS: an active-state element key rides on top of the base pin
    # (see `Context#id_style_state_vars` — base merged, state wins)
    # and darkens the bezel like AppKit (`ACCENT_PRESSED`), instead of
    # painting the same blue in every state — a button that never
    # reacts looks like it doesn't take the click at all.
    def self.default_button(ui : Ui, text : String,
                            id : String? = nil) : Response
      btn = Button.new(text, id: id)
      btn.style do |s|
        s.background = ACCENT
        s.text_color = Color32.rgb(255, 255, 255)
        s.stroke = ACCENT
      end
      response = ui.add(btn)
      ctx = ui.ctx
      ctx.set_id_style(response.id, "background", ACCENT)
      ctx.set_id_style(response.id, "text_color",
        Color32.rgb(255, 255, 255))
      ctx.set_id_style(response.id, "stroke", ACCENT)
      ctx.set_id_style(response.id, "background", ACCENT_PRESSED,
        state: "active")
      ctx.set_id_style(response.id, "stroke", ACCENT_PRESSED,
        state: "active")
      response
    end
  end
end
