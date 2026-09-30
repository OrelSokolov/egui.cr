# TextCmd's family field + Context#fonts_for (pure headless — the font
# CHAIN itself lives in spec/font_chain_smoke.cr, a runnable script,
# because instantiating an AtlasFonts subclass here would pull the
# C-shim LightHintedFonts into the virtual Fonts dispatch and link the
# native lib into `crystal spec`).

require "spec"
require "../src/egui"

describe Egui::TextCmd do
  it "defaults to the primary stack; family \"monospace\" opts into the mono stack" do
    cmd = Egui::TextCmd.new(Egui::Rect.zero, Egui::Pos2.zero, "x", 12.0,
      Egui::Color32.rgb(255, 255, 255))
    cmd.family.should be_nil

    ctx = Egui::Context.new
    ctx.mono_font.same?(ctx.fonts).should be_true # nil = primary
    ctx.mono_fonts = Egui::MonospaceFonts.new
    ctx.mono_font.same?(ctx.fonts).should be_false

    p = Egui::Painter.new
    p.text(Egui::Pos2.zero, "x", 12.0, Egui::Color32.rgb(255, 255, 255),
      family: "monospace")
    p.commands.last.as(Egui::TextCmd).family.should eq("monospace")
  end
end

describe Egui::Context do
  it "resolves named families with primary as the fallback" do
    ctx = Egui::Context.new
    named = Egui::MonospaceFonts.new
    ctx.register_font_family("term", named)

    ctx.fonts_for(nil).same?(ctx.fonts).should be_true
    ctx.fonts_for("").same?(ctx.fonts).should be_true # "" is not a family
    ctx.fonts_for("term").same?(named).should be_true
    ctx.fonts_for("typo").same?(ctx.fonts).should be_true # unknown → primary

    mono = Egui::MonospaceFonts.new
    ctx.register_font_family("monospace", mono)
    ctx.mono_font.same?(mono).should be_true # reserved name → mono slot
  end
end
