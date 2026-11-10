# Canvas2D specs (NativeHTML §4.3 Route A): the browser-canvas surface
# — fills/strokes through the NanoSVG CPU bake, CTM at record time,
# gradients, globalAlpha compositing, clear_rect, clip, fill_text
# through the font atlas readback, version-driven rebake, texture
# lifecycle. Headless: the DummyTextureRegistry keeps upload pixels, so
# assertions read the baked RGBA straight from the registry.
require "spec"
require "../src/egui"

C2D_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def canvas2d_step(ctx : Egui::Context, c : Egui::Canvas2D,
                  &app : Egui::Canvas2D ->) : Nil
  raw = Egui::RawInput.new(C2D_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    ui.canvas2d(c) { |cv| app.call(cv) }
  end
  ctx.end_frame
end

# Runs one frame (drawing through the block) and returns the baked
# texture pixels: {w, h, rgba}.
def canvas2d_bake(c : Egui::Canvas2D, ctx : Egui::Context) : {Int32, Int32, Bytes}
  canvas2d_step(ctx, c) { }
  px = ctx.textures.pixels(c.texture_id)
  raise "no baked texture" unless px
  px
end

def canvas2d_ctx : Egui::Context
  Egui::Context.new
end

def canvas2d_px(px : {Int32, Int32, Bytes}, x : Int32, y : Int32) : Egui::Color32
  w, _, data = px
  i = (y.to_i64 * w + x) * 4
  Egui::Color32.new(data[i], data[i + 1], data[i + 2], data[i + 3])
end

describe Egui::Canvas2D do
  it "fills a rect with the current fill style" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 20, 20)
    c.fill_rect(2.0, 2.0, 8.0, 8.0)
    c.fill_style = Egui::Color32.rgb(255, 0, 0)
    # Order matters like the browser: style read at the DRAW call.
    c2 = Egui::Canvas2D.new("t2", 20, 20)
    c2.fill_style = Egui::Color32.rgb(0, 0, 255)
    c2.fill_rect(2.0, 2.0, 8.0, 8.0)
    px = canvas2d_bake(c2, ctx)
    canvas2d_px(px, 5, 5).should eq Egui::Color32.rgb(0, 0, 255)
    canvas2d_px(px, 0, 0).a.should eq 0 # outside the rect: transparent
  end

  it "bakes once per version; style flips alone don't rebake" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 10, 10)
    c.fill_rect(1.0, 1.0, 5.0, 5.0)
    px = canvas2d_bake(c, ctx)
    id = c.texture_id
    canvas2d_step(ctx, c) { } # same version: no rebake, texture id kept
    c.texture_id.should eq id
    c.fill_style = Egui::Color32.rgb(9, 9, 9) # no op recorded
    canvas2d_step(ctx, c) { }
    canvas2d_px(ctx.textures.pixels(id).not_nil!, 3, 3).should eq Egui::Color32.rgb(0, 0, 0)
  end

  it "strokes with width and round caps, honoring line state" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 30, 30)
    c.stroke_style = Egui::Color32.rgb(0, 200, 0)
    c.line_width = 4.0
    c.line_cap = :round
    c.move_to(5.0, 15.0)
    c.line_to(25.0, 15.0)
    c.stroke
    px = canvas2d_bake(c, ctx)
    canvas2d_px(px, 15, 15).should eq Egui::Color32.rgb(0, 200, 0) # on the line
    canvas2d_px(px, 15, 15 - 2).a.should be > 0 # 4px stroke reaches ±2
    canvas2d_px(px, 15, 15 - 4).a.should eq 0     # beyond the width
  end

  it "applies the CTM at segment-add time (translate + scale)" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 40, 40)
    c.translate(10.0, 10.0)
    c.scale(2.0, 2.0)
    c.fill_rect(0.0, 0.0, 5.0, 5.0) # → (10,10)-(20,20) device
    px = canvas2d_bake(c, ctx)
    canvas2d_px(px, 15, 15).a.should eq 255
    canvas2d_px(px, 5, 5).a.should eq 0
  end

  it "rotates arcs converted to cubics" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 40, 40)
    c.fill_style = Egui::Color32.rgb(255, 255, 0)
    c.arc(20.0, 20.0, 10.0, 0.0, Math::PI * 2.0)
    c.fill
    px = canvas2d_bake(c, ctx)
    canvas2d_px(px, 20, 20).a.should eq 255          # center inside
    canvas2d_px(px, 20, 20 - 5).a.should eq 255      # inside (up)
    canvas2d_px(px, 20, 20 - 15).a.should eq 0       # outside the radius
  end

  it "fills with a linear gradient across the box" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 30, 10)
    g = c.create_linear_gradient(0.0, 0.0, 30.0, 0.0)
    g.add_color_stop(0.0, Egui::Color32.rgb(255, 0, 0))
    g.add_color_stop(1.0, Egui::Color32.rgb(0, 0, 255))
    c.fill_style = g
    c.fill_rect(0.0, 0.0, 30.0, 10.0)
    px = canvas2d_bake(c, ctx)
    left = canvas2d_px(px, 1, 5)
    right = canvas2d_px(px, 28, 5)
    left.a.should eq 255
    right.a.should eq 255
    (left.r > 200).should be_true  # red end
    (right.b > 200).should be_true # blue end
  end

  it "composites globalAlpha over existing content" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 10, 10)
    c.fill_style = Egui::Color32.rgb(255, 255, 255)
    c.fill_rect(0.0, 0.0, 10.0, 10.0)
    c.fill_style = Egui::Color32.rgb(0, 0, 0)
    c.global_alpha = 0.5
    c.fill_rect(0.0, 0.0, 10.0, 10.0)
    px = canvas2d_bake(c, ctx)
    mid = canvas2d_px(px, 5, 5)
    (mid.r > 90 && mid.r < 165).should be_true # ~50% gray
    mid.a.should eq 255
  end

  it "clear_rect erases back to transparent" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 10, 10)
    c.fill_rect(0.0, 0.0, 10.0, 10.0)
    c.clear_rect(2.0, 2.0, 4.0, 4.0)
    px = canvas2d_bake(c, ctx)
    canvas2d_px(px, 5, 5).a.should eq 0
    canvas2d_px(px, 8, 8).a.should eq 255
  end

  it "clips to the current path's bounding box" do
    ctx = canvas2d_ctx
    c = Egui::Canvas2D.new("t", 20, 20)
    c.rect(0.0, 0.0, 10.0, 20.0)
    c.clip
    c.fill_rect(0.0, 0.0, 20.0, 20.0)
    px = canvas2d_bake(c, ctx)
    canvas2d_px(px, 5, 10).a.should eq 255
    canvas2d_px(px, 15, 10).a.should eq 0
  end

  it "save/restore round-trips the working state" do
    c = Egui::Canvas2D.new("t", 10, 10)
    c.fill_style = Egui::Color32.rgb(1, 2, 3)
    c.global_alpha = 0.3
    c.save
    c.fill_style = Egui::Color32.rgb(9, 9, 9)
    c.global_alpha = 1.0
    c.restore
    c.fill_style.should eq Egui::Color32.rgb(1, 2, 3)
    c.global_alpha.should eq 0.3
  end

  it "skips text when the font stack has no rasterized atlas" do
    ctx = canvas2d_ctx # headless MonospaceFonts: coverage_quads is nil
    c = Egui::Canvas2D.new("t", 60, 20)
    c.fill_text("Hello", 2.0, 10.0)
    c.fill_rect(0.0, 0.0, 4.0, 4.0)
    px = canvas2d_bake(c, ctx)
    canvas2d_px(px, 2, 2).a.should eq 255 # shapes still bake
  end
end
