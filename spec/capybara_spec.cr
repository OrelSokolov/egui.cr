require "spec"
require "../src/egui"
require "../src/egui/capybara"
require "../src/egui/capybara/fonts"

# The app under test: counter button (explicit id), text field, slider,
# reaction labels — everything a Capybara tour exercises.

class CapyTourApp < Egui::App
  property count = 0
  property name = "Alice"
  property gain = 0.5_f64

  def update(ctx : Egui::Context) : Nil
    ctx.window("Tour", Egui::Pos2.new(40.0, 40.0), width: 420.0) do |ui|
      if ui.button("Increment", id: "inc").clicked?
        @count += 1
      end
      ui.label("count: #{@count}")
      ui.text_edit_singleline(@name) { |t| @name = t }
      ui.label("hello #{@name}")
      ui.slider(@gain, 0.0..1.0, "Gain") { |v| @gain = v }
    end
  end
end

def capy_tour(**opts) : Egui::Capybara::Session
  app = CapyTourApp.new
  Egui::Capybara::Fonts.install!(app.ctx)
  Egui::Capybara::Session.new(app, **opts)
end

describe Egui::Capybara do
  it "finds widgets by explicit id, label and kind" do
    t = capy_tour
    t.find("#inc").kind.should eq("Button")
    t.find("Increment").id_name.should eq("inc")
    t.find?("No Such Thing").should be_nil
    t.has_widget?("Button").should be_true
    t.all("Button").size.should be >= 1
  end

  it "raises ElementNotFound with an on-screen dump" do
    t = capy_tour
    ex = expect_raises(Egui::Capybara::ElementNotFound) { t.find("Missing") }
    ex.message.not_nil!.should contain("widgets on screen")
    ex.message.not_nil!.should contain("Button #inc")
  end

  it "clicks by label and by id, the app reacts" do
    t = capy_tour
    t.click("Increment")
    t.app.as(CapyTourApp).count.should eq(1)
    t.click("#inc")
    t.click("Increment")
    t.app.as(CapyTourApp).count.should eq(3)
    t.expect_text("count: 3")
  end

  it "fills a text field (focus + select all + type)" do
    t = capy_tour
    t.fill("TextEdit", "Bob")
    t.app.as(CapyTourApp).name.should eq("Bob")
    t.expect_text("hello Bob")
    t.expect_no_text("hello Alice")
  end

  it "drags a slider by kind selector" do
    t = capy_tour
    slider = t.find("Slider")
    t.drag(slider, Egui::Pos2.new(slider.rect.right - 4.0,
      slider.rect.center.y))
    t.app.as(CapyTourApp).gain.should be > 0.9
  end

  it "screenshots the frame as a PNG of the session size" do
    t = capy_tour(width: 500, height: 400)
    t.click("Increment")
    path = "tmp/capybara_spec_shot.png"
    t.screenshot(path)
    File.exists?(path).should be_true
    bytes = File.read(path).to_slice
    # PNG signature + IHDR dimensions (big-endian u32 at offsets 16/20)
    bytes[0, 8].should eq(Bytes[137, 80, 78, 71, 13, 10, 26, 10])
    w = (bytes[16].to_u32 << 24) | (bytes[17].to_u32 << 16) |
        (bytes[18].to_u32 << 8) | bytes[19]
    h = (bytes[20].to_u32 << 24) | (bytes[21].to_u32 << 16) |
        (bytes[22].to_u32 << 8) | bytes[23]
    w.should eq(500)
    h.should eq(400)
    bytes.size.should be > 5_000 # real content, not an empty buffer
  end

  it "suite runs scenarios on fresh apps and reports failures" do
    suite = Egui::Capybara::Suite.new(-> { CapyTourApp.new.as(Egui::App) },
      shots_dir: "tmp/capybara")
    suite.scenario "increments" do |t|
      t.click "Increment"
      t.expect_text "count: 1"
    end
    suite.scenario "boom" do |t|
      t.expect_text "never on screen"
    end
    io = IO::Memory.new
    failures = suite.run(io)
    out = io.to_s
    failures.should eq(1)
    out.should contain("✓ increments")
    out.should contain("✗ boom")
    out.should contain("1/2 passed")
    # failure auto-screenshot
    File.exists?("tmp/capybara/fail_boom.png").should be_true
  end

  it "expect_text failure lists what IS on screen" do
    t = capy_tour
    ex = expect_raises(Egui::Capybara::ExpectationFailed) do
      t.expect_text("nope")
    end
    ex.message.not_nil!.should contain("count: 0")
  end
end
