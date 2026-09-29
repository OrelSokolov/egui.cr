# Router specs: the page-based app architecture — Route parsing
# (window/page#fragment), the navigate/back stack, per-frame page
# declaration through ctx.routes, the soft "page not found" warning
# page, modal pages (addressable overlays rendered over the base
# page) and the --page fragment landing keyboard focus.

require "spec"
require "../src/egui"

ROUTER_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def router_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016, & : Egui::Router ->) : Nil
  ctx.begin_frame(Egui::RawInput.new(ROUTER_SCREEN, events, time))
  ctx.routes { |r| yield r }
  ctx.end_frame
end

# A two-page + one-modal app used across the specs below.
def routed_app(ctx : Egui::Context, ran : Hash(String, Bool),
               events : Array(Egui::Event) = [] of Egui::Event) : Nil
  ctx.begin_frame(Egui::RawInput.new(ROUTER_SCREEN, events, 0.016))
  ctx.routes do |r|
    r.page "root/root" do |ui|
      ran["root"] = true
      ui.label("home")
    end
    r.page "root/settings", title: "Settings" do |ui|
      ran["settings"] = true
      ui.add(Egui::TextEdit.new("", hint: "search", focus_id: "search"))
    end
    r.modal "root/confirm", title: "Sure?" do |ui|
      ran["confirm"] = true
      ui.label("confirm body")
    end
  end
  ctx.end_frame
end

describe Egui::Route do
  it "parses window/page#fragment" do
    r = Egui::Route.parse("root/settings#search").not_nil!
    r.window.should eq("root")
    r.page.should eq("settings")
    r.fragment.should eq("search")
    r.to_s.should eq("root/settings#search")

    bare = Egui::Route.parse("settings").not_nil!
    bare.window.should eq("root")
    bare.page.should eq("settings")
    bare.fragment.should be_nil
    bare.page_id.should eq("root/settings")

    Egui::Route.parse("root/root").not_nil!.fragment.should be_nil
  end

  it "rejects garbage and foreign windows (soft — nil, never raise)" do
    Egui::Route.parse("").should be_nil
    Egui::Route.parse("a/b/c").should be_nil
    Egui::Route.parse("win2/settings").should be_nil # one window today
    Egui::Route.parse("root/").should be_nil
  end

  it "== compares by value" do
    Egui::Route.parse("root/root").should eq(Egui::Route.root)
  end
end

describe Egui::Router do
  it "starts at root/root and the stack obeys navigate/back/replace" do
    ctx = Egui::Context.new
    r = ctx.router
    r.current.should eq(Egui::Route.root)

    r.navigate("root/settings")
    r.current.page_id.should eq("root/settings")

    # Navigating to a page already in the stack goes back to it.
    r.navigate("root/root")
    r.current.page_id.should eq("root/root")
    r.back # nothing below home — stays
    r.current.should eq(Egui::Route.root)

    r.navigate("root/settings")
    r.back
    r.current.should eq(Egui::Route.root)

    r.navigate("root/settings")
    r.replace("root/confirm")
    r.current.page_id.should eq("root/confirm")
  end

  it "soft-warns and ignores unparsable addresses" do
    ctx = Egui::Context.new
    ctx.router.navigate("win2/nope")
    ctx.router.navigate("a/b/c")
    ctx.router.current.should eq(Egui::Route.root)
  end

  it "renders only the top full page; the stack below is skipped" do
    ctx = Egui::Context.new
    ran = {} of String => Bool
    routed_app(ctx, ran) # first frame at root/root
    ran.keys.should eq(["root"])

    ctx.router.navigate("root/settings")
    ran.clear
    routed_app(ctx, ran)
    ran.keys.should eq(["settings"])
    # a full page bites the whole window
    ctx.available_rect.height.should be <= 0.0
  end

  it "renders the base page under a modal route and dims it (modal = page)" do
    ctx = Egui::Context.new
    ran = {} of String => Bool
    ctx.router.navigate("root/confirm")
    routed_app(ctx, ran)
    ran.keys.should contain("root")
    ran.keys.should contain("confirm")

    # The semi-transparent scrim over the base page.
    dim = ctx.style.visuals.modal_dim
    scrim = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == dim && c.rect.size == ROUTER_SCREEN.size }
    scrim.should_not be_nil
    dim.a.should be < 255 # see-through — that is the point of a modal page

    # Modal blocking latches from the next begin_frame.
    ctx.begin_frame(Egui::RawInput.new(ROUTER_SCREEN, [] of Egui::Event, 0.032))
    ctx.memory.modal_open?.should be_true
    ctx.end_frame
  end

  it "the page back button pops the stack" do
    ctx = Egui::Context.new
    ctx.router.navigate("root/settings")
    ran = {} of String => Bool
    routed_app(ctx, ran)

    # The round back button: 8pt inset, 32pt box, centered in the 44pt
    # header (see page_spec).
    pos = Egui::Pos2.new(
      Egui::Page::BACK_PAD + Egui::Page::BACK_D / 2.0,
      Egui::Page::HEADER_H / 2.0)
    routed_app(ctx, ran, [Egui::Event.pointer_pressed(pos)])
    ctx.router.current.page_id.should eq("root/settings") # press is not a click
    routed_app(ctx, ran, [Egui::Event.pointer_released(pos)])
    ctx.router.current.should eq(Egui::Route.root)
  end

  it "an unknown page renders the soft not-found page" do
    ctx = Egui::Context.new
    ctx.router.navigate("root/void")
    ran = {} of String => Bool
    routed_app(ctx, ran)
    ran.should be_empty # no app page ran

    text = ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).join
    text.should contain("Page not found")
    text.should contain("root/void")
    # the warning page still claims the window (a page, not a toast)
    ctx.available_rect.height.should be <= 0.0
  end

  it "a #fragment lands keyboard focus on the focus_id widget" do
    ctx = Egui::Context.new
    ctx.router.navigate("root/settings#search")
    ran = {} of String => Bool
    routed_app(ctx, ran) # focus.request latches — current from next frame
    routed_app(ctx, ran)
    ran.keys.should eq(["settings"])

    id = Egui::Id.from("page/settings")
      .child(Egui::Id.from("named/search").value)
    ctx.memory.focus.has_focus?(id).should be_true
  end

  it "a fragment for another page does not focus this page's widget" do
    ctx = Egui::Context.new
    ctx.router.navigate("root/confirm#search") # no focus_id in the modal
    ran = {} of String => Bool
    routed_app(ctx, ran)
    id = Egui::Id.from("page/settings")
      .child(Egui::Id.from("named/search").value)
    ctx.memory.focus.has_focus?(id).should be_false
  end

  it "the modal scrim IS the back: a click outside the card pops it" do
    ctx = Egui::Context.new
    ctx.router.navigate("root/confirm")
    ran = {} of String => Bool
    routed_app(ctx, ran) # frame 1: sizes the card, modal latches

    outside = Egui::Pos2.new(40.0, 40.0) # dimmed area, far from the card
    routed_app(ctx, ran, [Egui::Event.pointer_pressed(outside)])
    ctx.router.current.page_id.should eq("root/confirm") # press ≠ click
    routed_app(ctx, ran, [Egui::Event.pointer_released(outside)])
    ctx.router.current.page_id.should eq("root/root")
  end

  it "a click ON the modal card does not pop the route" do
    ctx = Egui::Context.new
    ctx.router.navigate("root/confirm")
    ran = {} of String => Bool
    routed_app(ctx, ran)

    on_card = Egui::Pos2.new(400.0, 300.0) # card center (480x220, centered)
    routed_app(ctx, ran, [Egui::Event.pointer_pressed(on_card)])
    routed_app(ctx, ran, [Egui::Event.pointer_released(on_card)])
    ctx.router.current.page_id.should eq("root/confirm")
  end

  it "an app that never declares routes leaves the router idle" do
    ctx = Egui::Context.new
    ctx.router.navigate("root/anything")
    ctx.begin_frame(Egui::RawInput.new(ROUTER_SCREEN, [] of Egui::Event, 0.016))
    ctx.end_frame # no ctx.routes — nothing renders, nothing raises
    ctx.available_rect.height.should be > 0.0
  end

  it "ctx-level panels inside a page render inside it (deferred central too)" do
    # Regression: the deferred central panel used to render in
    # end_frame AFTER the page bit the remainder — into an empty rect,
    # the routed-notepad empty-editor lesson. The page must flush it
    # before biting.
    ctx = Egui::Context.new
    ran = {} of String => Bool
    router_frame(ctx) do |r|
      r.page "root/root" do
        ctx.menu_bar { |bar| ran["menu"] = true }
        ctx.central_panel do |ui|
          ran["central"] = true
          ui.label("editor content")
        end
        ctx.bottom_panel("status", height: 30.0) { |ui| ran["status"] = true }
      end
    end
    ran.keys.should contain("central")
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).join.should contain("editor content")
  end
end

describe Egui::CLI do
  it "extracts --page and passes everything else through" do
    out = Egui::CLI.parse(["--page", "root/settings", "file.txt",
                           "--page=root/root#x"])
    out[:route].should eq("root/root#x") # last wins
    out[:argv].should eq(["file.txt"])
  end

  it "no --page means nil route, argv untouched" do
    out = Egui::CLI.parse(["a.txt", "b.txt"])
    out[:route].should be_nil
    out[:argv].should eq(["a.txt", "b.txt"])
  end
end
