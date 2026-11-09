# KDE platform theme — egui.cr painted like Breeze light (Plasma).
# Values measured from the native widget oracle (oracle/qt/png — see
# oracle/FINDINGS.md, the KDE section): real Qt 6.9 + Breeze 6.4
# QStyle widgets rendered headless (offscreen). Highlights: #EFF0F1
# windows, #E7E7E7-quiet bezels with #BFBFBF borders and ~3pt
# rounding, WHITE entries, dark #232629 marks inside light-blue
# checked checkboxes, muted #69A9D2 groove/progress fills, 6pt
# progress, outlined slider thumbs.
#
#   app.theme = Egui::KdeTheme.light
#
# Breeze paints no accent "default" push button (KDE dialogs keep
# plain bezels) — no default-button helper here.

require "./default_theme"

module Egui
  module KdeTheme
    # Breeze Blue (the default Plasma accent), sRGB.
    ACCENT = Color32.rgb(61, 174, 233)

    # The muted blue the Breeze QStyle paints on slider grooves and
    # progress chunks (measured on the oracle — NOT the raw accent).
    FILL = Color32.rgb(105, 169, 210)

    def self.light : Theme
      theme = DefaultTheme.build("kde", dark: false) do |v|
        v.panel_fill = Color32.rgb(239, 240, 241)  # Breeze Window role
        v.text_color = Color32.rgb(35, 38, 41)     # Breeze text
        v.window_fill = Color32.rgb(252, 252, 252) # Breeze View role
        # Breeze titlebars sit a step darker than the window body, so
        # the caption reads as its own band.
        v.title_bar_fill = Color32.rgb(242, 242, 242)
        v.window_stroke = Color32.rgb(191, 191, 191)
        # #EFF0F1 bezels with the #BFBFBF border (borders carry the
        # outline in Breeze, fills stay quiet).
        v.button_weak = Color32.rgb(239, 240, 241)
        v.button_hovered = Color32.rgb(222, 224, 226)
        v.button_active = Color32.rgb(203, 206, 209)
        v.button_stroke = Color32.rgb(191, 191, 191)
        v.selection_fill = ACCENT
        # Selected text paints the accent (white fg stays readable);
        # input focus rings the raw accent — see TextEdit/Textarea.
        v.text_selection_fill = ACCENT
        v.focus_ring_fill = ACCENT
        # Menu hover bands ride a pale accent tint (Breeze QMenu
        # hover; black label text stays readable).
        v.menu_highlight_fill = Color32.rgb(221, 237, 250)
      end

      style = theme.style
      style.font_size = 10.0 # Noto Sans system size
      style.title_font_size = 11.0
      sp = style.spacing
      sp.icon_width = 16.0        # checkbox/radio box
      sp.icon_width_inner = 6.0   # radio dot (Breeze dots are small)
      sp.slider_rail_width = 6.0  # Breeze groove (oracle: 77..82)
      # ~32pt buttons/fields (oracle): 10pt line ~14 + 2*9. The y
      # floor is the field's height floor too (max(line,interact.y)
      # + inset).
      sp.button_padding = Vec2.new(12.0, 8.5)
      sp.interact_size = Vec2.new(40.0, 14.0)

      sheet = theme.sheet

      # Push buttons: #EFF0F1 bezel on the same-tone window, #BFBFBF
      # border, ~3pt rounding (oracle corner insets 2,1,0).
      sheet.rule("button", StyleVars{
        "padding.top"    => 8.5,
        "padding.bottom" => 8.5,
        "padding.left"   => 12.0,
        "padding.right"  => 12.0,
        "rounding"       => 3.0,
        "background"     => Color32.rgb(239, 240, 241),
        "stroke"         => Color32.rgb(191, 191, 191),
      })
      sheet.rule("button:hover", StyleVars{
        "background" => Color32.rgb(222, 224, 226),
      })
      sheet.rule("button:active", StyleVars{
        "background" => Color32.rgb(203, 206, 209),
      })
      # The default theme ships touch-media button metrics (14/16
      # padding, 15pt font — the 44pt target). A Breeze look keeps the
      # ~32pt bezel at any width: re-declare the media rule with the
      # desktop metrics so narrow viewports don't grow the buttons.
      sheet.rule("button", StyleVars{
        "padding.top"    => 8.5,
        "padding.bottom" => 8.5,
        "padding.left"   => 12.0,
        "padding.right"  => 12.0,
        "font_size"      => 10.0,
        "rounding"       => 3.0,
        "background"     => Color32.rgb(239, 240, 241),
        "stroke"         => Color32.rgb(191, 191, 191),
      }, media: DefaultTheme::MOBILE_MAX)

      # Checkboxes/radios: 16pt box, #BFBFBF border, 2pt rounding.
      # Breeze 6 draws DARK marks: the checked box fills with a light
      # blue selection mix and a #232629 check; the selected radio's
      # dot is #232629, not accent.
      sheet.rule("checkbox", StyleVars{
        "box_fill"    => Color32.rgb(255, 255, 255),
        "box_stroke"  => Color32.rgb(191, 191, 191),
        "check_width" => 2.2,
        "rounding"    => 2.0,
      })
      sheet.rule("checkbox:checked", StyleVars{
        "box_fill"    => Color32.rgb(161, 188, 206),
        "check_color" => Color32.rgb(35, 38, 41),
      })
      sheet.rule("radio:selected", StyleVars{
        "dot_fill" => Color32.rgb(35, 38, 41),
      })

      # Switches (ToggleButton): QtWidgets has no switch primitive —
      # metrics from the Breeze Quick style: ~46x23 capsule, off =
      # light #FCFCFC track + white round knob, on = accent.
      sheet.rule("toggle_button", StyleVars{
        "sync_with_text" => false,
        "tumbler_size"   => 23.0,
        "track_width"    => 46.0,
        "knob_width"     => 19.0,
        "knob_color"     => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(191, 191, 191),
        "track_fill"     => Color32.rgb(252, 252, 252),
        "selection_fill" => ACCENT,
      })

      # Text fields/search: WHITE box (Breeze keeps entries white —
      # gray is GTK), #BFBFBF border, 2pt rounding, ~6pt text inset.
      sheet.rule("text_edit", StyleVars{
        "fill"           => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(191, 191, 191),
        "rounding"       => 2.0,
        "padding.top"    => 7.0,
        "padding.bottom" => 7.0,
        "padding.left"   => 6.0,
        "padding.right"  => 6.0,
      })
      # A search field (a TextEdit under the "search" style scope —
      # see Ui#with_style_scope) keeps the entry look in Breeze: the
      # same 2pt rounding as plain fields, only the lens icon differs
      # (no rule needed — the base text_edit covers it).

      # Progress: thin 6pt track (oracle), small 2pt-rounded ends
      # (Breeze bars are near-square, not capsules), muted #69A9D2
      # fill, #CDCDCD track, no visible border.
      sheet.rule("progressbar", StyleVars{
        "width"          => 200.0,
        "height"         => 6.0,
        "rounding"       => 2.0,
        "selection_fill" => FILL,
        "stroke"         => Color32.rgb(205, 205, 205),
      })

      # Slider: 6pt #CDCDCD groove, muted #69A9D2 fill from the left
      # end up to the thumb, ~19pt OUTLINED circle thumb (light rim,
      # Breeze knobs are not filled) — the selection_fill slot on
      # Slider is the handle; fixed 220pt length.
      sheet.rule("slider", StyleVars{
        "width"          => 220.0,
        "handle_size"    => 9.5,
        "selection_fill" => Color32.rgb(252, 252, 252),
        "stroke"         => Color32.rgb(191, 191, 191),
        "fill"           => FILL,
      })

      # Segmented control: Qt has no native segmented — this maps it
      # to linked checkable tool buttons: #EFF0F1 3pt-rounding strip
      # with #BFBFBF borders; the CHECKED cell is gray #D1D1D1 with
      # dark text, NOT accent.
      sheet.rule("segmented", StyleVars{
        "padding.left"   => 16.0,
        "padding.right"  => 16.0,
        "padding.top"    => 8.0,
        "padding.bottom" => 8.0,
        "rounding"       => 3.0,
        "background"     => Color32.rgb(239, 240, 241),
        "stroke"         => Color32.rgb(191, 191, 191),
        "selection_fill" => Color32.rgb(209, 209, 209),
      })

      theme
    end
  end
end
