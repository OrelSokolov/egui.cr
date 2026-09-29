require "spec"
require "../src/egui"

# CustomCursorImage specs: buffer validation, the #same? dedupe the
# backend uploads by, and the Context per-frame lifecycle of
# `cursor_image` (upstream `PlatformOutput::cursor_image`). All
# headless — the backend application itself lives in the sokol shim.

CI_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def ci_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(CI_SCREEN, events, time))
end

describe Egui::CustomCursorImage do
  it "rejects a buffer not matching width*height*4" do
    expect_raises(ArgumentError) do
      Egui::CustomCursorImage.new(Bytes.new(15), 2, 2)
    end
  end

  it "rejects non-positive sizes" do
    expect_raises(ArgumentError) do
      Egui::CustomCursorImage.new(Bytes.new(0), 0, 4)
    end
  end

  it "clamps the hotspot into the image" do
    img = Egui::CustomCursorImage.new(Bytes.new(4 * 4 * 4), 4, 4, 9, -3)
    img.hotspot_x.should eq 3
    img.hotspot_y.should eq 0
  end

  it "same? is true only for the same buffer/geometry/hotspot" do
    rgba = Bytes.new(4 * 4 * 4)
    a = Egui::CustomCursorImage.new(rgba, 4, 4, 1, 2)
    b = Egui::CustomCursorImage.new(rgba, 4, 4, 1, 2)
    c = Egui::CustomCursorImage.new(rgba.dup, 4, 4, 1, 2) # same content, own buffer
    d = Egui::CustomCursorImage.new(rgba, 4, 4, 3, 2)     # same buffer, other hotspot
    a.same?(b).should be_true
    a.same?(c).should be_false
    a.same?(d).should be_false
  end
end

describe Egui::Context do
  it "resets cursor_image each begin_frame (like cursor_icon)" do
    ctx = Egui::Context.new
    ci_frame(ctx)
    ctx.cursor_image.should be_nil

    img = Egui::CustomCursorImage.new(Bytes.new(2 * 2 * 4), 2, 2)
    ctx.set_cursor_image(img)
    ctx.cursor_image.should eq img

    ci_frame(ctx, time: 0.032)
    ctx.cursor_image.should be_nil

    ctx.set_cursor_image(nil)
    ctx.cursor_image.should be_nil
  end

  it "cursor_image rides along cursor_icon, not instead of it" do
    ctx = Egui::Context.new
    ci_frame(ctx)
    ctx.set_cursor_icon(Egui::CursorIcon::Crosshair)
    img = Egui::CustomCursorImage.new(Bytes.new(4), 1, 1)
    ctx.set_cursor_image(img)
    ctx.cursor_icon.should eq Egui::CursorIcon::Crosshair
    ctx.cursor_image.should eq img # the backend picks which to apply
  end
end

describe Egui::Response do
  it "on_hover_cursor_image pushes the bitmap only while hovered" do
    ctx = Egui::Context.new
    img = Egui::CustomCursorImage.new(Bytes.new(4), 1, 1)
    resp = Egui::Response.new(ctx, Egui::Id.from("w"), Egui::Rect.zero,
      Egui::Sense.click_and_drag, false, false, 0, false,
      false, false, false, false, Egui::Vec2.zero)
    resp.on_hover_cursor_image(img)
    ctx.cursor_image.should be_nil
  end
end
