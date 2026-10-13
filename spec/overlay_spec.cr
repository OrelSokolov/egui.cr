# Overlay specs: region anchoring (the `position: fixed`-style
# floating block) — flow isolation, anchor/margin geometry, the style
# cascade for `anchor` (class rule + per-element inspector override),
# layer z, pass-through and inspector meta.

require "spec"
require "../src/egui"

OVERLAY_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def overlay_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                  time : Float64 = 0.016, &app : Egui::Context ->)
  ctx.begin_frame(Egui::RawInput.new(OVERLAY_SCREEN, events, time))
  yield ctx
  ctx.end_frame
end

# A fully controlled region: anchoring math is deterministic here,
# independent of the window's own padding.
def overlay_region : Egui::Rect
  Egui::Rect.from_min_size(Egui::Pos2.new(100.0, 100.0),
    Egui::Vec2.new(400.0, 300.0))
end

describe Egui::Overlay do
  it "does not advance the parent flow" do
    ctx = Egui::Context.new
    bx = by = ax = ay = 0.0
    bottom_before = bottom_after = 0.0
    overlay_frame(ctx) do |c|
      c.window("w") do |ui|
        ui.label("first")
        bx = ui.cursor.x
        by = ui.cursor.y
        bottom_before = ui.min_rect.bottom
        ui.overlay(:top_right) { |o| o.button("x") }
        ax = ui.cursor.x
        ay = ui.cursor.y
        bottom_after = ui.min_rect.bottom
      end
    end
    ax.should eq bx
    ay.should eq by
    bottom_after.should eq bottom_before
  end

  it "anchors top_right with the margin pushed inward (settled on the measured size)" do
    ctx = Egui::Context.new
    region = overlay_region
    margin = Egui::StyleBox.new(top: 5.0, right: 10.0)
    rect = nil
    2.times do |i|
      overlay_frame(ctx, time: 0.016 * (i + 1)) do |c|
        c.window("w") do |ui|
          rect = ui.overlay(:top_right, margin: margin, rect: region,
            id: "ov") { |o| o.button("Zoom") }.rect
        end
      end
    end
    r = rect.not_nil!
    r.right.should be_close(region.right - margin.right, 0.5)
    r.top.should be_close(region.top + margin.top, 0.5)
  end

  it "anchors center regardless of the content size" do
    ctx = Egui::Context.new
    region = overlay_region
    rect = nil
    2.times do |i|
      overlay_frame(ctx, time: 0.016 * (i + 1)) do |c|
        c.window("w") do |ui|
          rect = ui.overlay(:center, rect: region) { |o| o.spinner }.rect
        end
      end
    end
    r = rect.not_nil!
    r.center.x.should be_close(region.center.x, 0.5)
    r.center.y.should be_close(region.center.y, 0.5)
  end

  it "anchor flips through the overlay class rule" do
    ctx = Egui::Context.new
    region = overlay_region
    ctx.stylesheet.rule("overlay", Egui::StyleVars{"anchor" => "center"})
    rect = nil
    2.times do |i|
      overlay_frame(ctx, time: 0.016 * (i + 1)) do |c|
        c.window("w") do |ui|
          rect = ui.overlay(:top_right, rect: region,
            id: "ov") { |o| o.button("Zoom") }.rect
        end
      end
    end
    r = rect.not_nil!
    r.center.x.should be_close(region.center.x, 0.5)
    r.center.y.should be_close(region.center.y, 0.5)
  end

  it "anchor flips through a per-element inspector override" do
    ctx = Egui::Context.new
    region = overlay_region
    ctx.set_id_style(Egui::Id.from("ov"), "anchor", "bottom_left")
    rect = nil
    2.times do |i|
      overlay_frame(ctx, time: 0.016 * (i + 1)) do |c|
        c.window("w") do |ui|
          rect = ui.overlay(:top_right, rect: region,
            id: "ov") { |o| o.button("Zoom") }.rect
        end
      end
    end
    r = rect.not_nil!
    r.left.should be_close(region.left, 0.5)
    r.bottom.should be_close(region.bottom, 0.5)
  end

  it "z lifts the content into the given layer" do
    ctx = Egui::Context.new
    region = overlay_region
    2.times do |i|
      overlay_frame(ctx, time: 0.016 * (i + 1)) do |c|
        c.window("w") do |ui|
          ui.overlay(:center, rect: region, z: 60) do |o|
            o.button("Zoom", id: "zoom_btn")
          end
        end
      end
    end
    layer = ctx.memory.prev_widget_layers[Egui::Id.from("zoom_btn")]?
    layer.not_nil!.z.should eq 60
  end

  it "registers a background pick by default; pass_through drops it" do
    ctx = Egui::Context.new
    region = overlay_region
    pos = region.center
    # Three frames: #widgets_at reads PREV-frame rects, and the button
    # only centers on the frame after the content is first measured.
    3.times do |i|
      overlay_frame(ctx, time: 0.016 * (i + 1)) do |c|
        c.window("w") do |ui|
          # The centered button ends up under `pos`; the background
          # target (when present) covers it too.
          ui.overlay(:center, rect: region, id: "ov") do |o|
            o.button("HUD", id: "hud_btn")
          end
        end
      end
    end
    ctx.memory.widgets_at(pos).size.should eq 2

    ctx = Egui::Context.new
    3.times do |i|
      overlay_frame(ctx, time: 0.016 * (i + 1)) do |c|
        c.window("w") do |ui|
          ui.overlay(:center, rect: region, id: "ov",
            pass_through: true) do |o|
            o.button("HUD", id: "hud_btn")
          end
        end
      end
    end
    ctx.memory.widgets_at(pos).size.should eq 1
  end

  it "records inspector meta with anchor/margin/z props" do
    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    overlay_frame(ctx) do |c|
      c.inspector.before_update
      c.window("w") do |ui|
        ui.overlay(:top_right, id: "ov") { |o| o.button("Zoom") }
      end
    end
    m = ctx.inspector.meta_for(Egui::Id.from("ov")).not_nil!
    m.kind.should eq "Overlay"
    m.display_class.should eq "overlay"
    keys = m.props.map(&.key)
    keys.should contain("anchor")
    keys.should contain("margin")
    keys.should contain("z")
    anchor_prop = m.props.find { |p| p.key == "anchor" }.not_nil!
    anchor_prop.options.should eq Egui::Overlay::ANCHORS
  end
end
