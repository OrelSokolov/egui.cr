# Egui::EmbeddedWindow — the Firefox-style About dialog as a window
# inside the window (on top of Context#embedded_window): icon |
# name/version/update/description block, links row, small footer.
require "spec"
require "../src/egui"
require "./core_spec" # raw_frame helper + SCREEN

describe "EmbeddedWindow" do
  it "renders the Firefox-style blocks and closes on the ✕" do
    ctx = Egui::Context.new
    win = Egui::EmbeddedWindow.new(
      "About app",
      version: "1.2.3",
      description: "a multiline description\nwith two lines of text",
      links: [
        {"Licensing", "https://example.com/license"},
        {"End User Rights", "https://example.com/eula"},
        {"Privacy policy", "https://example.com/privacy"},
      ],
      footer: "© 2026 the app contributors",
      update_label: "Check for updates")

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      closed = win.show(ctx)
      ctx.end_frame
      closed
    end

    # Two frames to measure; every block's text is painted.
    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)).should be_false }
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    {"About app", "Version 1.2.3", "Check for updates", "Licensing",
     "End User Rights", "Privacy policy", "© 2026 the app contributors"}
      .each { |t| texts.should contain(t) }

    # The ✕ (registered under "embedded/about_window/close") closes.
    close_rect = ctx.memory.widget_rects[Egui::Id.from("embedded/about_window/close")].not_nil!
    center = close_rect.center
    draw.call([Egui::Event.pointer_moved(center),
               Egui::Event.pointer_pressed(center)], 0.064).should be_false
    draw.call([Egui::Event.pointer_released(center)], 0.080).should be_true
  end

  it "fires on_update and shows the live status line" do
    ctx = Egui::Context.new
    win = Egui::EmbeddedWindow.new("About app", version: "1.0",
      update_label: "Check for updates")
    win.on_update = ->{ win.update_status = "Up to date"; nil }

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      win.show(ctx)
      ctx.end_frame
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    btn = ctx.memory.widget_rects[Egui::Id.from("about_window_update")].not_nil!
    center = btn.center
    draw.call([Egui::Event.pointer_moved(center),
               Egui::Event.pointer_pressed(center),
               Egui::Event.pointer_released(center)], 0.064)
    win.update_status.should eq("Up to date")
    draw.call([] of Egui::Event, 0.080)
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("Up to date")
  end

  it "uses the Win11 chrome: red hover on the close button, no title band" do
    ctx = Egui::Context.new
    win = Egui::EmbeddedWindow.new("About app")

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      win.show(ctx)
      ctx.end_frame
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    close_rect = ctx.memory.widget_rects[Egui::Id.from("embedded/about_window/close")].not_nil!
    # The Win11 close button: 46×32 flush to the corner (the app
    # window's own caption button geometry).
    close_rect.width.should be_close(46.0, 0.5)
    close_rect.height.should be_close(32.0, 0.5)

    # Hover: the Windows system red highlight (#C42B1C).
    center = close_rect.center
    draw.call([Egui::Event.pointer_moved(center)], 0.064)
    red = ctx.painter.commands.select(Egui::RectCmd).any? do |c|
      (f = c.fill) && f.r == 196 && f.g == 43 && f.b == 28
    end
    red.should be_true
  end

  it "stretches the icon to at least 200pt of window height" do
    ctx = Egui::Context.new
    icon_svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#777"/></svg>)
    win = Egui::EmbeddedWindow.new("About app", version: "1.0",
      description: "short text", icon: icon_svg)
    3.times do |i|
      raw_frame(ctx, time: 0.016 * (i + 1))
      win.show(ctx).should be_false
      ctx.end_frame
    end
    # The A block's icon side floors the whole card height at 400pt
    # (plus caption/pads/B on top of it).
    size = ctx.memory.layer_sizes[Egui::Id.from("embedded/about_window")].not_nil!
    size.y.should be >= 200.0
    # …and a window without an icon stays compact.
    ctx2 = Egui::Context.new
    plain = Egui::EmbeddedWindow.new("About app", description: "short text")
    3.times do |i|
      raw_frame(ctx2, time: 0.016 * (i + 1))
      plain.show(ctx2)
      ctx2.end_frame
    end
    size2 = ctx2.memory.layer_sizes[Egui::Id.from("embedded/about_window")].not_nil!
    size2.y.should be < 200.0
  end

  it "hides the optional pieces when they are not given" do
    ctx = Egui::Context.new
    win = Egui::EmbeddedWindow.new("About app")
    raw_frame(ctx, time: 0.016)
    win.show(ctx).should be_false
    ctx.end_frame
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("About app")
    texts.should_not contain("Check for updates")
  end
end
