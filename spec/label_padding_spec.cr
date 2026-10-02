require "spec"
require "../src/egui"

LABEL_PAD_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def label_pad_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(LABEL_PAD_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "label CSS padding" do
  it "defaults to zero (no size change without a rule)" do
    ctx = Egui::Context.new
    plain = nil

    label_pad_frame(ctx) do |c|
      c.central_panel do |ui|
        plain = ui.label("Hello").rect
      end
    end

    # No padding rule → the rect is exactly the galley size; compare a
    # run with and without the rule below instead of hardcoding glyph
    # metrics: the unpadded rect must equal a fresh-context twin.
    ctx2 = Egui::Context.new
    twin = nil
    label_pad_frame(ctx2) do |c|
      c.central_panel do |ui|
        twin = ui.label("Hello").rect
      end
    end
    plain.not_nil!.size.should eq(twin.not_nil!.size)
  end

  it "scalar shorthand grows the rect on all sides" do
    ctx = Egui::Context.new
    bare = nil

    label_pad_frame(ctx) do |c|
      c.central_panel do |ui|
        bare = ui.label("Hello").rect
      end
    end

    ctx2 = Egui::Context.new
    ctx2.stylesheet.rule("label", Egui::StyleVars{"padding" => 10.0})
    padded = nil
    label_pad_frame(ctx2) do |c|
      c.central_panel do |ui|
        padded = ui.label("Hello").rect
      end
    end

    b = bare.not_nil!.size
    p = padded.not_nil!.size
    p.x.should eq(b.x + 20.0)
    p.y.should eq(b.y + 20.0)
  end

  it "per-side keys beat the scalar shorthand per side" do
    ctx = Egui::Context.new
    bare = nil
    label_pad_frame(ctx) do |c|
      c.central_panel do |ui|
        bare = ui.label("Hello").rect
      end
    end

    ctx2 = Egui::Context.new
    ctx2.stylesheet.rule("label", Egui::StyleVars{
      "padding"       => 10.0,
      "padding.right" => 4.0,
      "padding.bottom" => 4.0,
    })
    padded = nil
    label_pad_frame(ctx2) do |c|
      c.central_panel do |ui|
        padded = ui.label("Hello").rect
      end
    end

    b = bare.not_nil!.size
    p = padded.not_nil!.size
    p.x.should eq(b.x + 10.0 + 4.0)   # left 10 (shorthand), right 4
    p.y.should eq(b.y + 10.0 + 4.0)   # top 10 (shorthand), bottom 4
  end

  it "offsets the drawn text into the content box" do
    run = ->(pad : Bool?) do
      ctx = Egui::Context.new
      if pad
        ctx.stylesheet.rule("label", Egui::StyleVars{
          "padding.left" => 7.0,
          "padding.top"  => 5.0,
        })
      end
      rect = nil
      label_pad_frame(ctx) do |c|
        c.central_panel do |ui|
          rect = ui.add(Egui::Label.new("Hello", userselect: false)).rect
        end
      end
      cmd = ctx.painter.commands.select(Egui::TextCmd)
        .find { |t| t.text.includes?("Hello") }.not_nil!
      {rect.not_nil!, cmd.pos}
    end

    bare_rect, bare_pos = run.call(nil)
    pad_rect, pad_pos = run.call(true)
    # The text pen (TextCmd.pos) rides the row center — compare the
    # PADDED-vs-BARE deltas, not absolute offsets.
    (pad_pos.x - bare_pos.x).should be_close(7.0, 0.01)
    (pad_pos.y - bare_pos.y).should be_close(5.0, 0.01)
    (pad_rect.left - bare_rect.left).should be_close(0.0, 0.01)
    (pad_rect.top - bare_rect.top).should be_close(0.0, 0.01)
  end

  it "declares the padding style property for the inspector" do
    props = Egui::Label.new("x").style_properties
    props.any? { |pr| pr.key == "padding" && pr.kind == :box }.should be_true
  end
end
