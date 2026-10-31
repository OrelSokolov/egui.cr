require "../src/egui"
require "./core_spec" # raw_frame helper + SCREEN

# Locate a painted text's center (footer buttons are found by label,
# the banner by title) — the click target for the pointer events.
private def text_center(ctx, text)
  cmd = ctx.painter.commands.select(Egui::TextCmd)
    .find { |c| c.text == text }
  cmd.should_not be_nil
  c = cmd.not_nil!
  Egui::Pos2.new(c.pos.x + 20.0, c.pos.y)
end

describe Egui::Wizard do
  it "renders the banner (title + subtitle), body and the standard footer" do
    ctx = Egui::Context.new
    wizard = Egui::Wizard.new("Setup", [
      Egui::WizardStep.new("Welcome", "Subtitle here") { |ui| ui.label("BODY") },
      Egui::WizardStep.new("Second", "") { |ui| ui.label("two") },
    ])
    raw_frame(ctx, time: 0.016)
    wizard.show(ctx)
    ctx.end_frame

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Setup")              # embedded window title bar
    texts.should contain("Welcome")            # banner title
    texts.should contain("Subtitle here")      # banner subtitle
    texts.should contain("BODY")               # step body
    texts.should contain("Next")             # footer
    texts.should contain("Cancel")
    texts.should_not contain("Back")         # first step: no Back
    texts.should_not contain("Finish")         # not the last step
  end

  it "navigates forward and back, and the last step shows Finish" do
    ctx = Egui::Context.new
    wizard = Egui::Wizard.new("Setup", [
      Egui::WizardStep.new("One", "") { |ui| ui.label("step one") },
      Egui::WizardStep.new("Two", "") { |ui| ui.label("step two") },
    ])
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      done = wizard.show(ctx)
      ctx.end_frame
      done
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    next_c = text_center(ctx, "Next")
    draw.call([Egui::Event.pointer_moved(next_c),
               Egui::Event.pointer_pressed(next_c)], 0.048)
    draw.call([Egui::Event.pointer_moved(next_c),
               Egui::Event.pointer_released(next_c)], 0.064)
    draw.call([] of Egui::Event, 0.080) # the advance shows next frame

    wizard.index.should eq(1)
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("step two")
    texts.should contain("Back")
    texts.should contain("Finish") # last step: Next became Finish
  end

  it "fires on_next before advancing and gates Next with can_next" do
    ctx = Egui::Context.new
    fired = 0
    step = Egui::WizardStep.new("One", "") { |ui| ui.label("x") }
    step.on_next { |_w| fired += 1 }
    step.can_next { |_w| false } # gate closed
    wizard = Egui::Wizard.new("Setup", [
      step,
      Egui::WizardStep.new("Two", "") { |ui| ui.label("y") },
    ])

    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      wizard.show(ctx)
      ctx.end_frame
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    # disabled Next: clicks must not land (ui.enabled blocks interaction)
    next_c = text_center(ctx, "Next")
    draw.call([Egui::Event.pointer_moved(next_c),
               Egui::Event.pointer_pressed(next_c),
               Egui::Event.pointer_released(next_c)], 0.048)
    wizard.index.should eq(0) # gate held the wizard in place
    fired.should eq(0)

    # gate opens -> the click advances and fires on_next first
    step.can_next { |_w| true }
    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 4)) }
    next_c = text_center(ctx, "Next")
    draw.call([Egui::Event.pointer_moved(next_c),
               Egui::Event.pointer_pressed(next_c)], 0.096)
    draw.call([Egui::Event.pointer_moved(next_c),
               Egui::Event.pointer_released(next_c)], 0.112)
    wizard.index.should eq(1)
    fired.should eq(1)
  end

  it "finishes on the last step's Finish and reports done via #show" do
    ctx = Egui::Context.new
    wizard = Egui::Wizard.new("Setup", [
      Egui::WizardStep.new("One", "") { |ui| ui.label("x") },
    ])
    done = false
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      done = wizard.show(ctx)
      ctx.end_frame
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    done.should be_false
    fin = text_center(ctx, "Finish")
    draw.call([Egui::Event.pointer_moved(fin),
               Egui::Event.pointer_pressed(fin)], 0.048)
    draw.call([Egui::Event.pointer_moved(fin),
               Egui::Event.pointer_released(fin)], 0.064)
    wizard.finished?.should be_true
    done.should be_true
  end

  it "renders a step's custom button set with custom actions" do
    ctx = Egui::Context.new
    clicked = [] of String
    step = Egui::WizardStep.new("One", "") { |ui| ui.label("x") }
    step.buttons = [
      Egui::Wizard::Button.custom("Apply") { |_w| clicked << "apply" },
      Egui::Wizard::Button.cancel,
    ]
    wizard = Egui::Wizard.new("Setup", [step])
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw_frame(ctx, events: events, time: time)
      done = wizard.show(ctx)
      ctx.end_frame
      done
    end

    2.times { |i| draw.call([] of Egui::Event, 0.016 * (i + 1)) }
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Apply")
    texts.should contain("Cancel")
    texts.should_not contain("Next") # fully replaced footer

    apply = text_center(ctx, "Apply")
    draw.call([Egui::Event.pointer_moved(apply),
               Egui::Event.pointer_pressed(apply)], 0.048)
    draw.call([Egui::Event.pointer_moved(apply),
               Egui::Event.pointer_released(apply)], 0.064)
    clicked.should eq(["apply"])

    cancel = text_center(ctx, "Cancel")
    draw.call([Egui::Event.pointer_moved(cancel),
               Egui::Event.pointer_pressed(cancel)], 0.080)
    draw.call([Egui::Event.pointer_moved(cancel),
               Egui::Event.pointer_released(cancel)], 0.096)
    wizard.cancelled?.should be_true
  end

  it "fires on_show once per step entry" do
    ctx = Egui::Context.new
    shown = [] of Int32
    s1 = Egui::WizardStep.new("One", "") { |ui| ui.label("x") }
    s1.on_show { |_w| shown << 1 }
    s2 = Egui::WizardStep.new("Two", "") { |ui| ui.label("y") }
    s2.on_show { |_w| shown << 2 }

    wizard = Egui::Wizard.new("Setup", [s1, s2])
    3.times do |i|
      raw_frame(ctx, time: 0.016 * (i + 1))
      wizard.show(ctx)
      ctx.end_frame
    end
    shown.should eq([1]) # s1 shown once, not per frame

    wizard.next!
    3.times do |i|
      raw_frame(ctx, time: 0.016 * (i + 4))
      wizard.show(ctx)
      ctx.end_frame
    end
    shown.should eq([1, 2])
  end
end

describe "Wizard sizing + SideImage" do
  it "auto-sizes to ~90% of the host window" do
    ctx = Egui::Context.new
    wizard = Egui::Wizard.new("Setup", [
      Egui::WizardStep.new("One", "") { |ui| ui.label("x") },
      Egui::WizardStep.new("Two", "") { |ui| ui.label("y") },
    ])
    raw_frame(ctx, time: 0.016)
    wizard.show(ctx)
    ctx.end_frame

    # the card spans ~90% of the 800pt screen (720, give or take padding)
    shell = ctx.painter.commands.select(Egui::RectCmd)
      .reject { |c| c.rect.width >= 800.0 }
      .max_by { |c| c.rect.width * c.rect.height }.rect
    shell.width.should be_close(720.0, 24.0)
  end

  it "clamps to a too-small host window" do
    ctx = Egui::Context.new
    wizard = Egui::Wizard.new("Setup", [
      Egui::WizardStep.new("One", "") { |ui| ui.label("x") },
    ])
    small = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))
    ctx.begin_frame(Egui::RawInput.new(small, [] of Egui::Event, 0.016))
    wizard.show(ctx)
    ctx.end_frame
    shell = ctx.painter.commands.select(Egui::RectCmd)
      .reject { |c| c.rect.width >= 400.0 }
      .max_by { |c| c.rect.width * c.rect.height }.rect
    shell.width.should be <= 400.0 # the card never exceeds the window
  end

  it "paints the SideImage column and shifts the step content right" do
    svg = Egui::Svg.load("assets/icon.svg")
    body_x = {} of Bool => Float64
    [false, true].each do |with_side|
      ctx = Egui::Context.new
      step = Egui::WizardStep.new("One", "") { |ui| ui.label("BODY") }
      step.side_image = Egui::SideImage.new(svg) if with_side
      wizard = Egui::Wizard.new("Setup", [step])
      raw_frame(ctx, time: 0.016)
      wizard.show(ctx)
      ctx.end_frame
      cmd = ctx.painter.commands.select(Egui::TextCmd)
        .find { |c| c.text == "BODY" }.should_not be_nil
      body_x[with_side] = ctx.painter.commands
        .select(Egui::TextCmd).find { |c| c.text == "BODY" }.not_nil!.pos.x
      if with_side
        # the strip itself: a fill rect exactly the column width
        strip = ctx.painter.commands.select(Egui::RectCmd)
          .any? { |c| (c.rect.width - Egui::SideImage::DEFAULT_WIDTH).abs < 0.5 }
        strip.should be_true
      end
    end
    (body_x[true] - body_x[false]).should be >= Egui::SideImage::DEFAULT_WIDTH
  end

  it "SideImage fits the image aspect inside the strip box" do
    # a tall source in a wide short strip: capped by height, not width
    tall = Egui::Svg.new(%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 200"><rect width="100" height="200" fill="black"/></svg>))
    side = Egui::SideImage.new(tall, width: 100.0)
    side.width.should eq(100.0)
  end
end

describe "Wizard proportional resize" do
  it "keeps the card ~90% of the host window on BOTH axes, whatever the content" do
    ctx = Egui::Context.new
    wizard = Egui::Wizard.new("Setup", [
      Egui::WizardStep.new("One", "") { |ui| ui.label("short") },
      # a step far taller than the 90% body area — must scroll, not grow
      Egui::WizardStep.new("Tall", "") { |ui| 60.times { |i| ui.label("line #{i}") } },
    ])
    draw = ->(time : Float64) do
      raw_frame(ctx, time: time)
      wizard.show(ctx)
      ctx.end_frame
    end
    2.times { |i| draw.call(0.016 * (i + 1)) }
    shell = ctx.painter.commands.select(Egui::RectCmd)
      .reject { |c| c.rect.width >= 800.0 }
      .max_by { |c| c.rect.width * c.rect.height }.rect
    shell.width.should be_close(720.0, 24.0)
    shell.height.should be <= 600.0

    wizard.next!
    2.times { |i| draw.call(0.016 * (i + 3)) }
    tall = ctx.painter.commands.select(Egui::RectCmd)
      .reject { |c| c.rect.width >= 800.0 }
      .max_by { |c| c.rect.width * c.rect.height }.rect
    # same proportional card on the tall step: no growth, no reflow
    (tall.height - shell.height).abs.should be <= 2.0
    (tall.width - shell.width).abs.should be <= 2.0
    # the content rides inside the scrolled viewport: the visible head
    # paints, the far tail (past the ~90% card) is clipped away
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("line 0")
    texts.should_not contain("line 59")
  end
end
