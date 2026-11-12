# box-shadow showcase — every ShadowCmd shape on one clean canvas,
# painted directly through `Painter#box_shadow` (no widget chrome, no
# stylesheets): the same card painted with a ladder of blurs, offsets,
# spreads, insets, and the html_gallery "floating" case. Compare with
# any browser: each case's CSS is in the label.
#
#   blur ladder   box-shadow: 0 4px {b}px rgba(0,0,0,.5)
#   offset ladder box-shadow: 0 {o}px 12px rgba(0,0,0,.5)
#   spread ladder box-shadow: 0 4px 12px rgba(0,0,0,.5) spread {s}px
#   inset ladder  box-shadow: inset 0 2px {b}px rgba(0,0,0,.6)

require "../src/egui/driver_selector"

class BoxShadowShowcase < Egui::App
  BG     = Egui::Color32.rgb(0x23, 0x23, 0x29) # page
  CARD   = Egui::Color32.rgb(0x2e, 0x2e, 0x36) # card fill
  LABEL  = Egui::Color32.rgb(0xe8, 0xe8, 0xec)
  DIM    = Egui::Color32.rgb(0x9a, 0x9a, 0xa6)
  OUT    = Egui::Color32.rgba(0, 0, 0, 128)    # rgba(0,0,0,.5)
  INK    = Egui::Color32.rgba(0, 0, 0, 153)    # rgba(0,0,0,.6)

  CW = 120.0 # card size
  CH = 70.0

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      p = ui.painter
      p.rect(Egui::Rect.from_min_size(Egui::Pos2.new(0, 0),
        Egui::Vec2.new(ctx.input.screen_rect.width,
          ctx.input.screen_rect.height)), 0.0, BG)
      font = ui.style.font_size

      section = ->(y : Float64, title : String) : Float64 do
        p.text(Egui::Pos2.new(24, y + 10), title, font, DIM)
        y + 26
      end

      card = ->(x : Float64, y : Float64, label : String,
                blur : Float64, offset : Egui::Vec2, spread : Float64,
                inset : Bool) : Nil do
        r = Egui::Rect.from_min_size(Egui::Pos2.new(x + 20, y + 16),
          Egui::Vec2.new(CW, CH))
        unless inset # outset rides UNDER the fill, inset OVER it
          p.box_shadow(r, OUT, blur: blur, rounding: 8.0,
            spread: spread, offset: offset)
        end
        p.rect(r, 8.0, CARD)
        if inset
          p.box_shadow(r, INK, blur: blur, rounding: 8.0,
            spread: spread, offset: offset, inset: true)
        end
        p.text(Egui::Pos2.new(x + 20 + CW / 2, y + 16 + CH / 2),
          label, font, LABEL)
      end

      # painter.text anchors LEFT-CENTER; nudge the title baselines.
      y = 8.0

      y = section.call(y, "outset — blur ladder (0 4px B .5)")
      {0.0, 2.0, 4.0, 8.0, 16.0, 32.0}.each_with_index do |b, i|
        card.call(24 + i * (CW + 24), y, b.to_i.to_s, b,
          Egui::Vec2.new(0, 4), 0.0, false)
      end
      y += CH + 40

      y = section.call(y, "outset — offset ladder (0 O 12px .5)")
      {0.0, 2.0, 4.0, 8.0, 16.0}.each_with_index do |o, i|
        card.call(24 + i * (CW + 24), y, o.to_i.to_s, 12.0,
          Egui::Vec2.new(0, o), 0.0, false)
      end
      y += CH + 40

      y = section.call(y, "outset — spread ladder (0 4px 12px .5 + S)")
      {-4.0, 0.0, 4.0, 8.0, 16.0}.each_with_index do |s, i|
        card.call(24 + i * (CW + 24), y, s.to_i.to_s, 12.0,
          Egui::Vec2.new(0, 4), s, false)
      end
      y += CH + 40

      y = section.call(y, "inset — blur ladder (inset 0 2px B .6)")
      {2.0, 4.0, 8.0, 16.0, 32.0}.each_with_index do |b, i|
        card.call(24 + i * (CW + 24), y, b.to_i.to_s, b,
          Egui::Vec2.new(0, 2), 0.0, true)
      end
      y += CH + 40

      y = section.call(y, "html_gallery case (0 4px 12px .5 / inset 0 2px 8px .6)")
      r = Egui::Rect.from_min_size(Egui::Pos2.new(44, y + 16),
        Egui::Vec2.new(280, 60))
      p.box_shadow(r, OUT, blur: 12.0, rounding: 8.0,
        offset: Egui::Vec2.new(0, 4))
      p.rect(r, 8.0, Egui::Color32.rgb(0x26, 0x26, 0x2d))
      p.box_shadow(r, INK, blur: 8.0, rounding: 8.0,
        offset: Egui::Vec2.new(0, 2), inset: true)
      p.text(Egui::Pos2.new(r.center.x, r.center.y), "floating", font, LABEL)

      r2 = Egui::Rect.from_min_size(Egui::Pos2.new(400, y + 16),
        Egui::Vec2.new(280, 60))
      p.box_shadow(r2, OUT, blur: 24.0, rounding: 12.0,
        offset: Egui::Vec2.new(0, 8), spread: 4.0)
      p.rect(r2, 12.0, CARD)
      p.text(Egui::Pos2.new(r2.center.x, r2.center.y), "elevated", font, LABEL)
    end
  end
end

Egui.run(BoxShadowShowcase.new,
  title: "egui.cr — box-shadow showcase", width: 980, height: 760,
  inspector: :hidden)
