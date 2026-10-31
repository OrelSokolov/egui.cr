# OvalProgress specs — headless: the two-strip pill geometry (radius
# = height / 2 for BOTH strips), the gradient fill and the percent
# width math, rendered through the real exml renderer.

require "spec"
require "../src/egui"
require "../examples/oval_progress_components/oval_progress"

OVAL_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# One frame rendering `<oval_progress …/>` inside a window; returns
# the strip paint commands it produced (the window chrome is much
# taller and filtered out).
private def oval_frame(frac : String? = "0.5", height : String? = "12",
                       comp : OvalProgress = OvalProgress.new)
  renderer = Egui::Exml::Renderer.new
  renderer.component(comp)
  rt = Egui::Exml::Runtime.new
  attrs = %(height="#{height}") if height
  attrs = %(frac="#{frac}" #{attrs}) if frac
  node = Egui::Exml.parse_fragment(%(<oval_progress #{attrs}/>)).first
  ctx = Egui::Context.new
  ctx.begin_frame(Egui::RawInput.new(OVAL_SCREEN, [] of Egui::Event, 0.016))
  ctx.window("w") { |ui| renderer.render(node, ui, ctx, rt) }
  ctx.end_frame
  ctx.painter.commands.select(Egui::RectCmd)
    .select { |c| c.rounding > 0.0 && c.rect.height < 20.0 }
end

describe "oval_progress" do
  it "paints a pill track with a gradient pill fill inside (r = h/2)" do
    track, fill = oval_frame.not_nil!
    # the track: full height, radius = height / 2
    track.rect.height.should eq 12.0
    track.rounding.should eq 6.0
    track.fill.should eq Egui::Color32.rgb(0x43, 0x45, 0x4c) # theme gray (dark)
    track.fill2.should be_nil

    # the fill: pill of its own height (12 - 2*pad=2 → 8), inset by
    # the SAME pad on every side — left/right offset included
    fill.rect.height.should eq 8.0
    fill.rounding.should eq 4.0
    fill.rect.min.x.should be_close(track.rect.min.x + 2.0, 0.01)
    fill.rect.min.y.should be_close(track.rect.min.y + 2.0, 0.01)
    fill.rect.max.y.should be_close(track.rect.max.y - 2.0, 0.01)

    # width = frac × (track width minus the two side pads)
    fill.rect.width.should be_close((track.rect.width - 4.0) * 0.5, 0.51)

    # vertical gradient: голубой top → синий bottom
    fill.fill.should eq Egui::Color32.rgb(0x7f, 0xd0, 0xf9)
    fill.fill2.should eq Egui::Color32.rgb(0x16, 0x67, 0xd9)
  end

  it "takes the three colors as component parameters" do
    comp = OvalProgress.new
    comp.track_color = "#123456"
    comp.fill_from = "#abcdef"
    comp.fill_to = "#654321"
    track, fill = oval_frame(comp: comp).not_nil!
    track.fill.should eq Egui::Color32.rgb(0x12, 0x34, 0x56)
    fill.fill.should eq Egui::Color32.rgb(0xab, 0xcd, 0xef)
    fill.fill2.should eq Egui::Color32.rgb(0x65, 0x43, 0x21)
  end

  it "keeps the right pad at full progress" do
    track, fill = oval_frame(frac: "1").not_nil!
    fill.rect.max.x.should be_close(track.rect.max.x - 2.0, 0.51)
  end

  it "clamps tiny progress to a full circle (both caps visible)" do
    _, fill = oval_frame(frac: "0.005").not_nil!
    fill.rect.width.should be_close fill.rect.height, 0.01
    fill.rounding.should eq fill.rect.height / 2.0
  end

  it "paints no fill at frac 0" do
    rects = oval_frame(frac: "0").not_nil!
    rects.size.should eq 1 # the track alone
    rects.first.rect.height.should eq 12.0
  end
end
