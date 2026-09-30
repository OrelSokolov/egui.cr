# The font_family style cascade: a registered named family reaches the
# widgets through every cascade layer — the theme Style, class rules,
# and the inline `#style` builder — and rides the emitted TextCmds so
# the backend draws through the same stack the measurement used.
# Headless: stacks are plain MonospaceFonts, distinguished by instance.

require "spec"
require "../src/egui"

FONT_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def family_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(FONT_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

# A wider-than-default headless stack, so a family swap visibly changes
# measured widths (0.6 → 1.0 char-width factor).
class WideFonts < Egui::MonospaceFonts
  CHAR_W2 = 1.0

  def measure(text : String, size : Float64) : Egui::Vec2
    w = super
    Egui::Vec2.new(w.x / 0.6 * CHAR_W2, w.y)
  end
end

describe "font_family cascade" do
  it "swaps the font of a widget group through a class rule" do
    ctx = Egui::Context.new
    wide = WideFonts.new
    ctx.register_font_family("term", wide)
    ctx.stylesheet.rule("button", Egui::StyleVars{"font_family" => "term"})

    plain_width = nil
    termed_width = nil
    family_frame(ctx) do |c|
      c.central_panel do |ui|
        # The rule covers every Button — a whole widget group swaps its
        # font with one stylesheet line.
        plain_width = ui.ctx.fonts.measure("MMMM", ui.style.font_size).x
        termed_width = ui.add(Egui::Button.new("MMMM")).rect.width
      end
    end

    # The class-rule route must measure through the named stack: a
    # WideFonts char is 1.0*size wide vs the default 0.6*size.
    termed_width.not_nil!.should be > plain_width.not_nil! * 1.5
  end

  it "rides the paint commands the backend resolves" do
    ctx = Egui::Context.new
    ctx.register_font_family("term", WideFonts.new)

    cmd_family = nil
    family_frame(ctx) do |c|
      c.central_panel do |ui|
        label = Egui::Label.new("hi", userselect: false)
          .style do |s|
            s.font_family = "term"
          end
        ui.add(label)
      end
    end
    text = ctx.painter.commands.select(Egui::TextCmd)
      .find { |cmd| cmd.text == "hi" }
    cmd_family = text.try &.family
    cmd_family.should eq("term")
  end

  it "follows the theme Style app-wide" do
    ctx = Egui::Context.new
    ctx.style.font_family = "term"
    ctx.register_font_family("term", WideFonts.new)

    width = nil
    family_frame(ctx) do |c|
      c.central_panel do |ui|
        width = ui.add(Egui::Button.new("MMMM")).rect.width
      end
    end
    # 4 chars at 16px: 0.6 → 38.4px, 1.0 → 64px (+ padding in both).
    width.not_nil!.should be > 60.0
  end
end
