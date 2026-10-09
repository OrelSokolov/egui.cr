require "spec"
require "../src/egui"

CUTS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(900.0, 700.0))

def cuts_insp_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                   time : Float64 = 0.016, &app : Egui::Context ->)
  raw = Egui::RawInput.new(CUTS_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.inspector.before_update
  app.call(ctx)
  ctx.end_frame
end

describe Egui::FontCuts do
  describe "filename parsing" do
    it "reads the weight slot and slant off the style token" do
      c = Egui::FontCuts.parse("/x/NotoSans-BoldItalic.ttf")
      c.weight.should eq(700)
      c.italic.should be_true
      c.known.should be_true
      c.label.should eq("Bold 700 Italic")

      r = Egui::FontCuts.parse("/x/Ubuntu-R.ttf")
      r.weight.should eq(400)
      r.italic.should be_false

      sb = Egui::FontCuts.parse("/x/NotoSans-SemiBold.ttf")
      sb.weight.should eq(600)
      sb.italic.should be_false
    end

    it "marks width/shape tokens as unknown cuts" do
      c = Egui::FontCuts.parse("/x/NotoSans-ExtraCondensed.ttf")
      c.known.should be_false
    end

    it "folds legacy style-word families onto the base" do
      Egui::FontCuts.normalize_family("Noto Sans Thin").should eq("Noto Sans")
      Egui::FontCuts.normalize_family("Noto Sans Black Italic").should eq("Noto Sans")
      Egui::FontCuts.normalize_family("Noto Sans").should eq("Noto Sans")
    end

    it "names ladder slots" do
      Egui::FontCuts.weight_name(100).should eq("Thin")
      Egui::FontCuts.weight_name(700).should eq("Bold")
      Egui::FontCuts.weight_name(900).should eq("Black")
    end
  end

  describe "installed axis" do
    it "resolves real cuts for an installed family (degrades when absent)" do
      axis = Egui::FontCuts.axis("Noto Sans")
      if axis.empty?
        # nothing installed under the name — resolution degrades, no crash
        Egui::FontCuts.closest("Noto Sans", 700).should be_nil
      else
        axis.should contain(400)
        cut = Egui::FontCuts.closest("Noto Sans", 100).should_not be_nil
        thin = Egui::FontCuts.axis("Noto Sans").first
        Egui::FontCuts.closest("Noto Sans", thin).not_nil!.path
          .should start_with("/")
      end
    end

    it "returns no axis for unknown families and nil" do
      Egui::FontCuts.axis(nil).should be_empty
      Egui::FontCuts.axis("No Such Family XYZ").should be_empty
    end
  end
end

describe "Context#fonts_for_weight" do
  it "falls back to the bold flag for families without cuts" do
    ctx = Egui::Context.new
    fonts, family, bold = ctx.fonts_for_weight("No Such Family XYZ", nil, true)
    family.should eq("No Such Family XYZ")
    bold.should be_true
    fonts.same?(ctx.fonts_for("No Such Family XYZ")).should be_true

    _f2, fam2, bold2 = ctx.fonts_for_weight(nil, nil, false)
    fam2.should be_nil
    bold2.should be_false
  end

  it "routes a weighted family through the real cut stack" do
    skip_if = Egui::FontCuts.axis("Noto Sans").empty?
    pending "Noto Sans not installed" if skip_if

    ctx = Egui::Context.new
    fonts, family, bold = ctx.fonts_for_weight("Noto Sans", 100.0, false)
    family.should start_with("wght:")
    family.not_nil!.should contain("NotoSans")
    bold.should be_false
    # headless loader is nil — the stack degrades to the primary, and
    # the deferred entry is consumed by that first resolution
    # (#fonts_for_family drops it when nothing loads); re-resolving
    # still answers the same cut stack name.
    fonts.same?(ctx.fonts).should be_true
    _f3, fam3, _b3 = ctx.fonts_for_weight("Noto Sans", 100.0, false)
    fam3.should eq(family)
  end

  it "never substitutes a target that lands on the regular face" do
    ctx = Egui::Context.new
    fonts, family, bold = ctx.fonts_for_weight(nil, 400.0, false)
    family.should be_nil
    fonts.same?(ctx.fonts).should be_true
  end
end

describe "inspector smart weight selector" do
  it "offers the family's REAL cuts from the element tab" do
    pending "Noto Sans not installed" if Egui::FontCuts.axis("Noto Sans").empty?

    ctx = Egui::Context.new
    ctx.inspector_enabled = true
    # the label under inspection: family Noto Sans, weight 700 already
    # set through the class layer (the closed select then reads
    # "700 Bold", not the shared «(наследуется)» placeholder)
    ctx.stylesheet.rule("label", Egui::StyleVars{
      "font_family" => "Noto Sans",
      "font_weight" => 700.0,
    })

    smoke = 0.0
    cuts_insp_frame(ctx, time: (smoke += 0.016)) { |c| c.window("w") { |ui| ui.add(Egui::Label.new("lbl text", id: "lw")) } }
    ctx.inspector.selected = Egui::Id.from("lw")
    # the element tab is a manual switch now (Class is the default)
    ctx.inspector.tab = :element
    cuts_insp_frame(ctx, time: (smoke += 0.016)) { |c| c.window("w") { |ui| ui.add(Egui::Label.new("lbl text", id: "lw")) } }

    # the closed select shows the current cut by name
    btn = ctx.painter.commands.select(Egui::TextCmd)
      .find(&.text.==("700 Bold")).should_not be_nil

    # open it: the popup lists the family's real axis (Thin…Black),
    # and a pick writes the numeric slot through the setter
    click = Egui::Pos2.new(btn.pos.x + 10.0, btn.pos.y)
    cuts_insp_frame(ctx, [Egui::Event.pointer_moved(click),
      Egui::Event.pointer_pressed(click)], time: (smoke += 0.016)) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("lbl text", id: "lw")) }
    end
    cuts_insp_frame(ctx, [Egui::Event.pointer_released(click)],
      time: (smoke += 0.016)) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("lbl text", id: "lw")) }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("100 Thin")
    texts.should contain("900 Black")

    opt = ctx.painter.commands.select(Egui::TextCmd)
      .find { |t| t.text == "100 Thin" }.not_nil!
    pick = Egui::Pos2.new(opt.pos.x + 10.0, opt.pos.y)
    cuts_insp_frame(ctx, [Egui::Event.pointer_moved(pick),
      Egui::Event.pointer_pressed(pick)], time: (smoke += 0.016)) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("lbl text", id: "lw")) }
    end
    cuts_insp_frame(ctx, [Egui::Event.pointer_released(pick)],
      time: (smoke += 0.016)) do |c|
      c.window("w") { |ui| ui.add(Egui::Label.new("lbl text", id: "lw")) }
    end

    # the pick landed as a per-element override (the numeric slot)
    bag = ctx.id_style_overrides[Egui::Id.from("lw")].not_nil![nil].not_nil!
    bag["font_weight"].should eq(100.0)
  end
end

describe "label weight axis integration" do
  it "a family+weight rule draws through the real cut stack" do
    pending "Noto Sans not installed" if Egui::FontCuts.axis("Noto Sans").empty?

    ctx = Egui::Context.new
    ctx.stylesheet.rule("label", Egui::StyleVars{
      "font_family" => "Noto Sans",
      "font_weight" => 100.0,
    })
    cuts_insp_frame(ctx) { |c| c.central_panel { |ui| ui.label("Thin line") } }
    cmd = ctx.painter.commands.select(Egui::TextCmd)
      .find { |t| t.text.includes?("Thin line") }.not_nil!
    # headless measures through the primary stub, but the DRAW side is
    # told the real face: family = the cut's deferred stack name.
    cmd.family.not_nil!.should start_with("wght:")
    cmd.bold?.should be_false
  end
end
