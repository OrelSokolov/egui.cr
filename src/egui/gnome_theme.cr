# GNOME platform theme — egui.cr painted like libadwaita light
# (Adwaita). Values measured from the native widget oracle
# (oracle/gtk/png — see oracle/FINDINGS.md, the GNOME section): the
# real GTK 4.20/libadwaita 1.8 sheets render headless under Xvfb with
# Cantarell 11 vendored. Highlights: #FAFAFA windows, #E7E7E7 bezels
# with 6pt rounding, 34pt buttons/fields, unfocused entries GRAY (not
# white), 48x26 capsule switches, 4pt slider rails, 8pt progress.
#
#   app.theme = Egui::GnomeTheme.light
#
# Accent: the oracle machine pins Yaru purple as its compiled default
# (read-only), so accent surfaces use stock GNOME blue #3584E4 —
# upstream libadwaita's default. The suggested-action look (the
# accent-filled "OK"): GnomeTheme.suggested_button helper —
# WidgetStyle has no class layer for a "default" variant yet.

require "./default_theme"

module Egui
  module GnomeTheme
    # Stock GNOME blue (libadwaita's default accent), sRGB.
    ACCENT = Color32.rgb(53, 132, 228)

    def self.light : Theme
      theme = DefaultTheme.build("gnome", dark: false) do |v|
        v.panel_fill = Color32.rgb(250, 250, 250)   # window bg (oracle)
        v.text_color = Color32.rgb(61, 61, 61)      # label (oracle)
        v.window_fill = Color32.rgb(255, 255, 255)  # view bg
        # Adwaita headerbars are white with a 1px shade line under
        # them — the caption band reads apart from the window body.
        v.title_bar_fill = Color32.rgb(255, 255, 255)
        v.window_stroke = Color32.rgb(222, 222, 222)
        # Flat bezels: #E7E7E7 fills, #DEDEDE-ish soft borders.
        v.button_weak = Color32.rgb(231, 231, 231)
        v.button_hovered = Color32.rgb(222, 222, 222)
        v.button_active = Color32.rgb(211, 211, 211)
        v.button_stroke = Color32.rgb(222, 222, 222)
        v.selection_fill = ACCENT
        # Selected text paints the accent; input focus rings a softer
        # accent tint — see TextEdit/Textarea.
        v.text_selection_fill = ACCENT
        v.focus_ring_fill = Color32.rgb(155, 193, 246)
        # Popover menu hover bands are light gray.
        v.menu_highlight_fill = Color32.rgb(230, 230, 230)
      end

      style = theme.style
      style.font_size = 11.0 # Cantarell system size
      style.title_font_size = 12.0
      sp = style.spacing
      sp.icon_width = 19.0        # checkbox/radio box (oracle: ~19x19)
      sp.icon_width_inner = 7.0   # radio dot
      sp.slider_rail_width = 4.0  # thin GTK4 scale trough (oracle)
      # 34pt buttons/fields (oracle): 11pt Cantarell line ~16 + 2*9.
      # The y floor is the field's height floor too
      # (max(line, interact.y) + inset).
      sp.button_padding = Vec2.new(14.0, 9.0)
      sp.interact_size = Vec2.new(40.0, 16.0)

      sheet = theme.sheet

      # Push buttons: 34pt tall, #E7E7E7 flat bezel, 6pt rounding,
      # wide horizontal padding.
      sheet.rule("button", StyleVars{
        "padding.top"    => 9.0,
        "padding.bottom" => 9.0,
        "padding.left"   => 14.0,
        "padding.right"  => 14.0,
        "rounding"       => 6.0,
        "background"     => Color32.rgb(231, 231, 231),
        "stroke"         => Color32.rgb(222, 222, 222),
      })
      sheet.rule("button:hover", StyleVars{
        "background" => Color32.rgb(222, 222, 222),
      })
      sheet.rule("button:active", StyleVars{
        "background" => Color32.rgb(211, 211, 211),
      })
      # The default theme ships touch-media button metrics (14/16
      # padding, 15pt font — the 44pt target). A GNOME look keeps the
      # 34pt bezel at any width: CANCEL the media rule instead of
      # re-declaring it — the desktop rule above then holds everywhere.
      sheet.cancel_rule("button", media: DefaultTheme::MOBILE_MAX)

      # Checkboxes/radios: 19pt box, #DEDEDE ring, ~4.5pt rounding;
      # UNchecked fill is the window bg itself (native Adwaita leaves
      # it hollow); checked fills with the accent + a white mark.
      sheet.rule("checkbox", StyleVars{
        "box_fill"    => Color32.rgb(250, 250, 250),
        "box_stroke"  => Color32.rgb(222, 222, 222),
        "check_width" => 2.4,
        "rounding"    => 4.5,
      })
      sheet.rule("checkbox:checked", StyleVars{
        "box_fill"    => ACCENT,
        "check_color" => Color32.rgb(255, 255, 255),
      })
      sheet.rule("radio:selected", StyleVars{
        "dot_fill" => ACCENT,
      })

      # Switches (ToggleButton): 48x26 capsule (oracle) — off = WHITE
      # fill with a #DBDBDB rim (the knob rides on it with its own
      # shadow ring), on = accent with a white knob.
      sheet.rule("toggle_button", StyleVars{
        "sync_with_text" => false,
        "tumbler_size"   => 26.0,
        "track_width"    => 48.0,
        "knob_width"     => 22.0,
        "knob_color"     => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(219, 219, 219),
        "track_fill"     => Color32.rgb(255, 255, 255),
        "selection_fill" => ACCENT,
      })

      # Text fields/search: the unfocused Adwaita entry is a GRAY
      # 34pt #E7E7E7 box (white is the FOCUSED state — the focus ring
      # rule in TextEdit recolors), #DEDEDE border, 6pt rounding.
      sheet.rule("text_edit", StyleVars{
        "fill"           => Color32.rgb(231, 231, 231),
        "stroke"         => Color32.rgb(222, 222, 222),
        "rounding"       => 6.0,
        "padding.top"    => 8.0,
        "padding.bottom" => 8.0,
        "padding.left"   => 8.0,
        "padding.right"  => 8.0,
      })
      # A search field (a TextEdit under the "search" style scope —
      # see Ui#with_style_scope) keeps the entry look in Adwaita: the
      # same 6pt rounding as plain fields, only the lens icon differs
      # (no rule needed — the base text_edit covers it).

      # Progress: 8pt capsule track (oracle), accent fill,
      # track-colored stroke (no visible border — Adwaita has none).
      sheet.rule("progressbar", StyleVars{
        "width"          => 200.0,
        "height"         => 8.0,
        "rounding"       => "capsule",
        "selection_fill" => ACCENT,
        "stroke"         => Color32.rgb(222, 222, 222),
      })

      # Slider: white circular thumb (selection_fill slot on Slider is
      # the handle), #DEDEDE rail with a blue accent fill from the left
      # end up to the thumb, fixed 220pt length, ~19pt thumb (oracle).
      sheet.rule("slider", StyleVars{
        "width"          => 220.0,
        "handle_size"    => 9.5,
        "selection_fill" => Color32.rgb(255, 255, 255),
        "stroke"         => Color32.rgb(222, 222, 222),
        "fill"           => ACCENT,
      })

      # Segmented control: Adwaita has no native segmented — this maps
      # it to linked toggle buttons (the standard GNOME grouping), one
      # #E7E7E7 6pt-rounding strip with #C1C1C1 cell borders; the
      # CHECKED cell is gray #C1C1C1 with dark text, NOT accent.
      sheet.rule("segmented", StyleVars{
        "padding.left"   => 17.0,
        "padding.right"  => 17.0,
        "padding.top"    => 8.0,
        "padding.bottom" => 8.0,
        "rounding"       => 6.0,
        "background"     => Color32.rgb(231, 231, 231),
        "stroke"         => Color32.rgb(193, 193, 193),
        "selection_fill" => Color32.rgb(193, 193, 193),
      })

      theme
    end

    # The accent "suggested-action" push button (Adwaita's filled
    # call-to-action): blue bezel, white label. The inline `#style`
    # alone survives every state — the cascade contract puts inline
    # ABOVE class rules (inline beats `:hover`, CSS `style="…"`
    # semantics), so no per-element pinning is needed.
    def self.suggested_button(ui : Ui, text : String,
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
