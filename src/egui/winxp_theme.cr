# Windows XP (Luna) platform theme — egui.cr painted with the native XP
# system colors. Palette per the default XP install's color scheme
# (HKCU\Control Panel\Colors, cross-checked against the msstyles
# recreations XP.css and os-gui): #ECE9D8 face (ButtonFace/MenuBar),
# #316AC5 selection (Hilight/MenuHilight), #ACA899 3D shadow
# (ButtonShadow), #000080 hot-tracking, Luna scrollbar blues. Control
# metrics and the gradient push button come from the Paint XP demo
# (examples/paint_components — the same level of fidelity as the
# macOS/GNOME/KDE themes).
#
#   ctx.theme = Egui::WinXpTheme.light
#
# The window chrome is a separate layer — run the window with
# `chrome_style: Egui::WindowFrame::Style::WindowsXp` (or the Silver
# variant) to get the matching Luna titlebar; the caption constants are
# shared with it. Hand-painted chrome pieces that the class-rule sheet
# can't express live here as helpers: `.bevel` (the raised/sunken 1px
# toolbox cell) and `.push_button` (the Luna gradient button).

require "./default_theme"

module Egui
  module WinXpTheme
    # Dialog/panel face (#ECE9D8 — the classic 3D-face silver-cream).
    FACE = Color32.rgb(236, 233, 216)

    # Dialog BODY face (#F8F6E7 — lighter than the panels, the
    # jspaint/xp dialog background).
    DIALOG_FACE = Color32.rgb(248, 246, 231)

    WHITE     = Color32.rgb(255, 255, 255)
    BLACK     = Color32.rgb(0, 0, 0)
    # ButtonShadow (172 168 153) — the native XP 3D-shadow bevel color.
    BEVEL_DK  = Color32.rgb(172, 168, 153)
    # Classic caption navy (#0A246A) — the CLASSIC ActiveTitle; Luna's
    # own captions live in WindowFrame::WindowsXp. Kept for chrome
    # tweaks that want the dark navy.
    NAVY      = Color32.rgb(10, 36, 106)
    # Selected-tool / sunken-highlight fill (#B6BAC7).
    SEL_BG    = Color32.rgb(182, 186, 199)
    # Hilight / MenuHilight (49 106 197) — THE native XP selection blue:
    # menu bands, text selections, selected segments.
    HIGHLIGHT = Color32.rgb(49, 106, 197)
    # XP text-field border (#7F9DB9) — the thin blue inset ring.
    FIELD_STROKE = Color32.rgb(127, 157, 185)

    # Luna push button: light vertical gradient with a navy ring, the
    # XP orange glow on hover, sunken fill on press.
    PB_TOP      = Color32.rgb(255, 255, 255)
    PB_BOTTOM   = Color32.rgb(238, 235, 218)
    PB_RING     = Color32.rgb(0, 60, 116)
    PB_HOT_TOP  = Color32.rgb(255, 243, 200)
    PB_HOT_BOT  = Color32.rgb(255, 222, 155)
    PB_HOT_RING = Color32.rgb(198, 119, 0)
    PB_DOWN_TOP = Color32.rgb(224, 220, 200)
    PB_DOWN_BOT = Color32.rgb(205, 200, 176)

    def self.light : Theme
      theme = DefaultTheme.build("winxp", dark: false) do |v|
        # Native Luna system colors (HKCU\Control Panel\Colors of a
        # default XP install: ButtonFace/MenuBar 236 233 216, Hilight
        # and MenuHilight 49 106 197, ButtonShadow 172 168 153,
        # HotTrackingColor 0 0 128).
        v.window_fill = FACE
        v.window_stroke = BLACK
        v.window_rounding = 0.0
        v.panel_fill = FACE
        v.text_color = BLACK
        v.button_weak = FACE
        v.button_hovered = FACE
        v.button_active = FACE
        # Native menu selection (MenuHilight): the flat #316AC5 blue
        # band with white text. The button colors stay FACE on purpose
        # — toolbox-style apps draw their own bevel cells.
        v.menu_highlight_fill = HIGHLIGHT
        v.menu_highlight_text = WHITE
        # Luna scrollbars (per the msstyles recreations — XP.css /
        # os-gui): light-blue #C5D5FF thumb and arrow buttons, slate
        # arrows, near-white shaft.
        v.scrollbar_fill = Color32.rgb(0xc5, 0xd5, 0xff)
        v.scrollbar_arrow = Color32.rgb(0x6b, 0x75, 0x96)
        v.scrollbar_track = Color32.rgb(0xf1, 0xf1, 0xef)
        v.selection_fill = HIGHLIGHT
        v.hyperlink_color = Color32.rgb(0, 0, 128) # HotTrackingColor
        v.separator_color = BEVEL_DK
      end

      style = theme.style
      # Tahoma 8pt ≈ 11px — the XP system text size.
      style.font_size = 11.0
      sp = style.spacing
      # XP push button: 75×23 default, ~23pt tall at 11pt text.
      sp.button_padding = Vec2.new(12.0, 3.5)

      sheet = theme.sheet

      # Push buttons: Luna vertical gradient (top white → #EEEEDA) with
      # the navy #003C74 ring and 3pt rounding. `background2` rides the
      # state bag, so :hover/:active swap BOTH stops per state.
      sheet.rule("button", StyleVars{
        "padding.top"    => 3.5,
        "padding.bottom" => 3.5,
        "padding.left"   => 12.0,
        "padding.right"  => 12.0,
        "rounding"       => 3.0,
        "background"     => PB_TOP,
        "background2"    => PB_BOTTOM,
        "stroke"         => PB_RING,
      })
      # The XP orange hover glow.
      sheet.rule("button:hover", StyleVars{
        "background"  => PB_HOT_TOP,
        "background2" => PB_HOT_BOT,
        "stroke"      => PB_HOT_RING,
      })
      # Pressed: sunken flat fill, ring back to navy (the dialog chrome
      # pressed look).
      sheet.rule("button:active", StyleVars{
        "background"  => PB_DOWN_TOP,
        "background2" => PB_DOWN_BOT,
        "stroke"      => PB_RING,
      })
      # The default theme ships touch-media button metrics (the 44pt
      # target). An XP look keeps the 23pt bezel at any width: re-declare
      # the media rule with the desktop metrics so narrow viewports
      # don't grow the buttons.
      sheet.rule("button", StyleVars{
        "padding.top"    => 4.0,
        "padding.bottom" => 4.0,
        "padding.left"   => 12.0,
        "padding.right"  => 12.0,
        "font_size"      => 11.0,
        "rounding"       => 3.0,
        "background"     => PB_TOP,
        "background2"    => PB_BOTTOM,
        "stroke"         => PB_RING,
      }, media: DefaultTheme::MOBILE_MAX)

      # Checkboxes/radios: white sunken box with the XP field border,
      # black mark (XP checks black on white, no accent fill).
      sheet.rule("checkbox", StyleVars{
        "box_fill"    => Color32.rgb(255, 255, 255),
        "box_stroke"  => FIELD_STROKE,
        "check_color" => BLACK,
        "check_width" => 2.0,
        "rounding"    => 0.0,
      })
      sheet.rule("radio", StyleVars{
        "box_fill"   => Color32.rgb(255, 255, 255),
        "box_stroke" => FIELD_STROKE,
        "dot_fill"   => BLACK,
      })

      # Text fields: white box with the thin blue XP inset border,
      # square corners, tight ~8pt text inset.
      sheet.rule("text_edit", StyleVars{
        "fill"           => Color32.rgb(255, 255, 255),
        "stroke"         => FIELD_STROKE,
        "rounding"       => 0.0,
        "padding.top"    => 2.0,
        "padding.bottom" => 2.0,
        "padding.left"   => 6.0,
        "padding.right"  => 6.0,
      })

      # Progress: square Luna track, XP selection-blue fill.
      sheet.rule("progressbar", StyleVars{
        "width"          => 200.0,
        "height"         => 12.0,
        "rounding"       => 0.0,
        "selection_fill" => HIGHLIGHT,
        "stroke"         => BEVEL_DK,
      })

      # Slider: white sunken rail, Luna-blue thumb.
      sheet.rule("slider", StyleVars{
        "width"          => 220.0,
        "handle_size"    => 9.0,
        "selection_fill" => HIGHLIGHT,
        "stroke"         => BEVEL_DK,
        "fill"           => WHITE,
      })

      # Segmented control: XP has no native segmented — this maps it to
      # a row of Luna push buttons (the linked-toggle idiom): gradient
      # cells with the navy ring, the XP orange glow on hover, the
      # selected cell stays in the pressed/toggled state.
      sheet.rule("segmented", StyleVars{
        "padding.left"         => 12.0,
        "padding.right"        => 12.0,
        "padding.top"          => 3.5,
        "padding.bottom"       => 3.5,
        "rounding"             => 3.0,
        "background"           => PB_TOP,
        "background2"          => PB_BOTTOM,
        "stroke"               => PB_RING,
        "selection_fill"       => PB_DOWN_TOP,
        "selection_background2" => PB_DOWN_BOT,
        "selection_text"       => BLACK,
      })
      sheet.rule("segmented:hover", StyleVars{
        "background"  => PB_HOT_TOP,
        "background2" => PB_HOT_BOT,
        "stroke"      => PB_HOT_RING,
      })

      theme
    end

    # Raised/sunken 1px bevel box (the toolbox/toolstrip cell look):
    # fill first, then white/dark edges — raised puts the light on
    # top/left, sunken flips them. `fill` carries the highlight (e.g.
    # SEL_BG for a selected cell).
    def self.bevel(p : Painter, rect : Rect, sunken : Bool,
                   fill : Color32 = FACE) : Nil
      p.rect(rect, 0.0, fill)
      lo, hi = sunken ? {BEVEL_DK, WHITE} : {WHITE, BEVEL_DK}
      p.line(rect.min + Vec2.new(0.0, 0.5),
        Pos2.new(rect.max.x - 0.5, rect.min.y + 0.5), 1.0, lo)
      p.line(rect.min + Vec2.new(0.5, 0.0),
        Pos2.new(rect.min.x + 0.5, rect.max.y - 0.5), 1.0, lo)
      p.line(Pos2.new(rect.min.x + 0.5, rect.max.y - 0.5),
        Pos2.new(rect.max.x - 0.5, rect.max.y - 0.5), 1.0, hi)
      p.line(Pos2.new(rect.max.x - 0.5, rect.min.y + 0.5),
        Pos2.new(rect.max.x - 0.5, rect.max.y - 0.5), 1.0, hi)
    end

    # The Luna push button, hand-painted (the dialog-chrome path —
    # plain `ui.button` gets the same look from the sheet rules above):
    # vertical gradient + navy ring, orange glow on hover, sunken fill
    # while pressed, centered black label.
    def self.push_button(p : Painter, rect : Rect, label : String,
                         hovered : Bool, active : Bool,
                         fonts : Fonts, font_size : Float64 = 14.0) : Nil
      ring = hovered && !(active && hovered) ? PB_HOT_RING : PB_RING
      top, bottom = if active && hovered
                      {PB_DOWN_TOP, PB_DOWN_BOT}
                    elsif hovered
                      {PB_HOT_TOP, PB_HOT_BOT}
                    else
                      {PB_TOP, PB_BOTTOM}
                    end
      p.rect(rect, 3.0, top, ring, 1.0, bottom)
      tw = fonts.measure(label, font_size).x
      p.text(Pos2.new(rect.center.x - tw / 2.0, rect.center.y),
        label, font_size, BLACK)
    end
  end
end
