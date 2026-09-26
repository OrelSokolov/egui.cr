require "spec"
require "../src/egui"

# Hotkey layer specs: Hotkey parse/format/match, HotkeyMap bindings
# and dispatch, Context action events, the HotkeyEdit capture widget
# and action-driven menu items. All headless.

HK_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def hk_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
             time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(HK_SCREEN, events, time))
end

CTRL      = Egui::Modifiers.new(ctrl: true)
CTRL_SHIFT = Egui::Modifiers.new(ctrl: true, shift: true)

describe Egui::Hotkey do
  it "parses and formats back canonically" do
    Egui::Hotkey.parse("Ctrl+N").to_s.should eq "Ctrl+N"
    Egui::Hotkey.parse("ctrl+shift+z").to_s.should eq "Ctrl+Shift+Z"
    Egui::Hotkey.parse("Alt+F4").to_s.should eq "Alt+F4"
    Egui::Hotkey.parse("Ctrl+Space").to_s.should eq "Ctrl+Space"
    Egui::Hotkey.parse("Ctrl+1").to_s.should eq "Ctrl+1"
    Egui::Hotkey.parse("F5").to_s.should eq "F5"
    Egui::Hotkey.parse("Super+Q").to_s.should eq "Super+Q"
    Egui::Hotkey.parse("Esc").to_s.should eq "Escape"
    Egui::Hotkey.parse("Ctrl+Ins").to_s.should eq "Ctrl+Insert"
  end

  it "rejects garbage" do
    Egui::Hotkey.parse?("Ctrl+Foo").should be_nil
    Egui::Hotkey.parse?("N+C").should be_nil
    Egui::Hotkey.parse?("").should be_nil
    Egui::Hotkey.parse?("Ctrl").should be_nil # no key, only a modifier
    expect_raises(ArgumentError) { Egui::Hotkey.parse("Nope+X") }
  end

  it "is a value type — equality and hashing" do
    a = Egui::Hotkey.parse("Ctrl+N")
    b = Egui::Hotkey.new(Egui::KeyCode::N, ctrl: true)
    a.should eq b
    {a => 1}[b].should eq 1
    a.should_not eq Egui::Hotkey.parse("Ctrl+Shift+N")
  end

  it "matches a pressed key with exact modifiers" do
    ctx = Egui::Context.new
    hk_frame(ctx, [Egui::Event.key_pressed(:n, CTRL)])
    Egui::Hotkey.parse("Ctrl+N").matches?(ctx.input).should be_true
    Egui::Hotkey.parse("Ctrl+Shift+N").matches?(ctx.input).should be_false
    Egui::Hotkey.parse("N").matches?(ctx.input).should be_false
    Egui::Hotkey.parse("Ctrl+Q").matches?(ctx.input).should be_false
  end
end

describe Egui::HotkeyMap do
  it "keeps one hotkey per action and one action per hotkey" do
    map = Egui::HotkeyMap.new
    new_tab = Egui::HotkeyAction.new("app.new_tab")
    quit = Egui::HotkeyAction.new("app.quit")

    map.bind("Ctrl+N", new_tab)
    map.hotkey_for(new_tab).should eq Egui::Hotkey.parse("Ctrl+N")
    map.action_for(Egui::Hotkey.parse("Ctrl+N")).should eq new_tab

    # rebinding an action moves it
    map.bind("Ctrl+M", new_tab)
    map.hotkey_for(new_tab).should eq Egui::Hotkey.parse("Ctrl+M")
    map.action_for(Egui::Hotkey.parse("Ctrl+N")).should be_nil

    # a taken hotkey is replaced
    map.bind("Ctrl+Q", quit)
    map.bind("Ctrl+Q", new_tab)
    map.action_for(Egui::Hotkey.parse("Ctrl+Q")).should eq new_tab
    map.hotkey_for(quit).should be_nil

    # unbind_action clears
    map.unbind_action(new_tab)
    map.hotkey_for(new_tab).should be_nil
    map.action_for(Egui::Hotkey.parse("Ctrl+Q")).should be_nil
  end
end

describe Egui::Context do
  it "dispatches hotkey presses as one-frame action events" do
    ctx = Egui::Context.new
    action = Egui::HotkeyAction.new("app.new_tab")
    ctx.hotkeys.bind("Ctrl+N", action)

    hk_frame(ctx, [Egui::Event.key_pressed(:n, CTRL)])
    ctx.action_fired?(action).should be_true
    ctx.fired_actions.should eq [action]
    # exactly-once consumption
    ctx.consume_action(action).should be_true
    ctx.consume_action(action).should be_false
    # the key was claimed so widgets cannot also react to it
    ctx.input.key_pressed?(Egui::KeyCode::N).should be_false

    # next frame without a press: the firing expired
    hk_frame(ctx)
    ctx.action_fired?(action).should be_false
  end

  it "does not fire on modifier mismatch" do
    ctx = Egui::Context.new
    action = Egui::HotkeyAction.new("app.redo")
    ctx.hotkeys.bind("Ctrl+Shift+Z", action)

    hk_frame(ctx, [Egui::Event.key_pressed(:z, CTRL)])
    ctx.action_fired?(action).should be_false
  end

  it "fires actions programmatically (menu click path)" do
    ctx = Egui::Context.new
    action = Egui::HotkeyAction.new("app.quit")
    ctx.fire_action(action)
    ctx.consume_action(action).should be_true
  end

  it "pauses dispatch while a hotkey capture is active" do
    ctx = Egui::Context.new
    action = Egui::HotkeyAction.new("app.new_tab")
    ctx.hotkeys.bind("Ctrl+N", action)

    ctx.hotkey_capture_active!
    hk_frame(ctx, [Egui::Event.key_pressed(:n, CTRL)])
    ctx.action_fired?(action).should be_false

    # capture is one frame — a later press fires again
    hk_frame(ctx, [Egui::Event.key_pressed(:n, CTRL)], time: 0.032)
    ctx.action_fired?(action).should be_true
  end
end

describe Egui::HotkeyEdit do
  it "captures a combo on click and binds it to the action" do
    ctx = Egui::Context.new
    action = Egui::HotkeyAction.new("app.new_tab")
    received = nil
    center = nil

    show = -> do
      ctx.window("demo") do |ui|
        r = ui.hotkey_edit(action) { |hk| received = hk }
        center = r.rect.center
      end
    end

    # frame 1: layout — learn where the button is
    hk_frame(ctx, time: 0.016)
    show.call
    ctx.end_frame
    ctx.hotkeys.hotkey_for(action).should be_nil

    # frame 2: press, frame 3: release — the click starts capture
    hk_frame(ctx, events: [
      Egui::Event.pointer_moved(center.not_nil!),
      Egui::Event.pointer_pressed(center.not_nil!),
    ], time: 0.032)
    show.call
    ctx.end_frame
    hk_frame(ctx, events: [Egui::Event.pointer_released(center.not_nil!)],
      time: 0.048)
    show.call
    ctx.end_frame
    # capture has started: the button shows the waiting hint
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("press keys…")

    # frame 4: press Ctrl+K — captured and bound (dispatch was paused)
    hk_frame(ctx, events: [
      Egui::Event.key_pressed(:k, CTRL),
      Egui::Event.key_released(:k, CTRL),
    ], time: 0.064)
    show.call
    ctx.end_frame
    ctx.hotkeys.hotkey_for(action).should eq Egui::Hotkey.parse("Ctrl+K")
    received.should eq Egui::Hotkey.parse("Ctrl+K")
    ctx.action_fired?(Egui::HotkeyAction.new("app.new_tab")).should be_false

    # the bound hotkey shows on the button
    hk_frame(ctx, time: 0.080)
    show.call
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("Ctrl+K")
  end

  it "clears the binding with Backspace and cancels with Escape" do
    ctx = Egui::Context.new
    action = Egui::HotkeyAction.new("app.quit")
    ctx.hotkeys.bind("Ctrl+Q", action)
    center = nil

    show = ->do
      ctx.window("demo") do |ui|
        r = ui.hotkey_edit(action) { |hk| }
        center = r.rect.center
      end
    end

    hk_frame(ctx, time: 0.016)
    show.call
    ctx.end_frame
    hk_frame(ctx, events: [
      Egui::Event.pointer_moved(center.not_nil!),
      Egui::Event.pointer_pressed(center.not_nil!),
    ], time: 0.032)
    show.call
    ctx.end_frame
    hk_frame(ctx, events: [Egui::Event.pointer_released(center.not_nil!)],
      time: 0.048)
    show.call
    ctx.end_frame

    # Backspace while capturing clears the binding
    hk_frame(ctx, events: [Egui::Event.key_pressed(:backspace)],
      time: 0.064)
    show.call
    ctx.end_frame
    ctx.hotkeys.hotkey_for(action).should be_nil

    # click again, then Escape cancels — nothing captured, still unbound
    hk_frame(ctx, events: [
      Egui::Event.pointer_moved(center.not_nil!),
      Egui::Event.pointer_pressed(center.not_nil!),
    ], time: 0.080)
    show.call
    ctx.end_frame
    hk_frame(ctx, events: [Egui::Event.pointer_released(center.not_nil!)],
      time: 0.096)
    show.call
    ctx.end_frame
    hk_frame(ctx, events: [Egui::Event.key_pressed(:escape)], time: 0.112)
    show.call
    ctx.end_frame
    ctx.hotkeys.hotkey_for(action).should be_nil
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("(not bound)")
  end
end

describe "menu items" do
  it "display the bound hotkey and consume fired actions" do
    ctx = Egui::Context.new
    copy = Egui::HotkeyAction.new("edit.copy")
    ctx.hotkeys.bind("Ctrl+C", copy)
    fired = false
    pos = nil

    # frame 1: layout a label with a context menu
    hk_frame(ctx, time: 0.016)
    ctx.window("demo") do |ui|
      r = ui.label("right click me")
      pos = r.rect.center
      r.context_menu do |menu|
        menu.menu_item("Copy", copy) { fired = true }
      end
    end
    ctx.end_frame

    # frame 2: secondary press opens the menu — the item shows the
    # bound hotkey read from the map
    hk_frame(ctx, events: [
      Egui::Event.pointer_moved(pos.not_nil!),
      Egui::Event.pointer_pressed(pos.not_nil!, :secondary),
    ], time: 0.032)
    ctx.window("demo") do |ui|
      r = ui.label("right click me")
      r.context_menu do |menu|
        menu.menu_item("Copy", copy) { fired = true }
      end
    end
    ctx.end_frame
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("Ctrl+C")

    # frame 3: the action fires while the menu is open — the item
    # claims it and runs its block
    hk_frame(ctx, time: 0.048)
    ctx.fire_action(copy)
    ctx.window("demo") do |ui|
      r = ui.label("right click me")
      r.context_menu do |menu|
        menu.menu_item("Copy", copy) { fired = true }
      end
    end
    ctx.end_frame
    fired.should be_true
  end
end
