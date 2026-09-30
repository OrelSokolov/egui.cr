# Deferred font families (the system scan's output): names register
# cheaply into the catalog, the stack materializes through the loader
# on FIRST resolution only, and an unloadable family degrades to the
# primary stack. Plus the SelectBox widget: an editable combo — the
# closed selector IS the search field, typing filters the list below.

require "spec"
require "../src/egui"

SELECT_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

OPTIONS = ["Ubuntu", "Ubuntu Mono", "Roboto", "Liberation Mono"]
WALK_OPTIONS = (10..32).map(&.to_s)

def walk_frame(ctx : Egui::Context, selected : String,
                events : Array(Egui::Event), time : Float64,
                &block : String ->)
  raw = Egui::RawInput.new(SELECT_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    ui.select_box("walk", selected, WALK_OPTIONS, 80.0) { |opt| block.call(opt) }
  end
  ctx.end_frame
end

def select_frame(ctx : Egui::Context, selected : String,
                 buffer : String?, events : Array(Egui::Event), time : Float64,
                 &block : String ->)
  raw = Egui::RawInput.new(SELECT_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    # The edit buffer is SelectBox state in IdTypeMap under "sb/buf" —
    # seed it like typed text would have.
    if buffer
      ctx.memory.data.set_string(Egui::Id.from("sb/buf"), buffer)
    end
    ui.select_box("sb", selected, OPTIONS, 160.0) { |opt| block.call(opt) }
  end
  ctx.end_frame
end

describe "deferred font families" do
  it "lands in the catalog without loading; materializes once on first use" do
    ctx = Egui::Context.new
    ctx.register_deferred_font("Ubuntu", ["/fonts/Ubuntu-R.ttf"])
    ctx.font_family_catalog.should contain("Ubuntu")
    ctx.font_families.has_key?("Ubuntu").should be_false

    loads = 0
    wide = Egui::MonospaceFonts.new
    ctx.font_loader = ->(paths : Array(String)) : Egui::Fonts? {
      loads += 1
      paths.first.includes?("Ubuntu") ? wide : nil
    }
    ctx.fonts_for("Ubuntu").same?(wide).should be_true
    ctx.fonts_for("Ubuntu").same?(wide).should be_true
    loads.should eq(1) # cached in font_families — the loader ran once
    ctx.font_families["Ubuntu"].same?(wide).should be_true
    ctx.deferred_font_paths.has_key?("Ubuntu").should be_false
  end

  it "degrades an unloadable family to the primary without retrying" do
    ctx = Egui::Context.new
    ctx.register_deferred_font("Broken", ["/fonts/broken.ttf"])
    ctx.font_loader = ->(paths : Array(String)) : Egui::Fonts? { nil }
    ctx.fonts_for("Broken").same?(ctx.fonts).should be_true
    ctx.deferred_font_paths.has_key?("Broken").should be_false
  end

  it "rejects the reserved names" do
    ctx = Egui::Context.new
    ctx.register_deferred_font("system", ["/fonts/x.ttf"])
    ctx.register_deferred_font("monospace", ["/fonts/x.ttf"])
    ctx.deferred_font_paths.should be_empty
  end
end

describe Egui::SelectBox do
  it "shows the selection in the editable field" do
    ctx = Egui::Context.new
    picked = ""
    select_frame(ctx, "Roboto", nil, [] of Egui::Event, 0.016) { |o| picked = o }
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Roboto")
  end

  it "typing in the field replaces the value and opens a filtered list" do
    ctx = Egui::Context.new
    picked = ""
    # frame 0: idle — the widget registers its rect (a same-frame
    # press+release on the very first frame doesn't classify as a
    # click yet)
    select_frame(ctx, "Roboto", nil, [] of Egui::Event, 0.008) { |o| picked = o }
    # frame 1: click past the text — the caret seeds as a full
    # selection (URL-bar behavior), so typing REPLACES "Roboto"
    # instead of appending to it
    select_frame(ctx, "Roboto", nil,
      [Egui::Event.pointer_pressed(Egui::Pos2.new(100.0, 20.0)),
       Egui::Event.pointer_released(Egui::Pos2.new(100.0, 20.0))],
      0.016) { |o| picked = o }
    # frames 2..5: type "mono" — the first keystroke replaces, the
    # rest append; the list opens narrowed to the matching rows
    "mono".each_char_with_index do |ch, i|
      select_frame(ctx, "Roboto", nil, [Egui::Event.text_input(ch.to_s)],
        0.032 + (i + 1) * 0.016) { |o| picked = o }
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("mono") # the field itself
    texts.should contain("Ubuntu Mono")
    texts.should contain("Liberation Mono")
    # the non-matching options are NOT drawn as list rows
    texts.should_not contain("Ubuntu")
    texts.should_not contain("Roboto")

    # Enter confirms the first match: the pick lands, the list closes,
    # the field holds the value
    select_frame(ctx, "Roboto", nil,
      [Egui::Event.key_pressed(Egui::KeyCode::Enter)],
      0.112) { |o| picked = o }
    picked.should eq("Ubuntu Mono")
    ctx.popup_open?("sb").should be_false
    # the field shows the value from the next frame on (it was drawn
    # before the Enter branch rewrote the buffer)
    select_frame(ctx, "Ubuntu Mono", nil, [] of Egui::Event,
      0.128) { |o| picked = o }
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Ubuntu Mono")

    # The REAL backend sends Enter as KEY_DOWN + a CHAR event carrying
    # "\r" (sokol fires both) — the stray carriage return must neither
    # stick in the buffer nor block the confirm.
    ctx2 = Egui::Context.new
    picked2 = ""
    draw2 = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(SELECT_SCREEN, events, time)
      ctx2.begin_frame(raw)
      ctx2.central_panel do |ui|
        ui.select_box("s2", "Roboto", OPTIONS, 160.0) { |o| picked2 = o }
      end
      ctx2.end_frame
    end
    draw2.call([] of Egui::Event, 0.008)
    click = [Egui::Event.pointer_pressed(Egui::Pos2.new(100.0, 20.0)),
      Egui::Event.pointer_released(Egui::Pos2.new(100.0, 20.0))]
    draw2.call(click, 0.016)
    draw2.call([Egui::Event.text_input("m"), Egui::Event.text_input("o"),
      Egui::Event.text_input("n"), Egui::Event.text_input("o")], 0.032)
    draw2.call([Egui::Event.key_pressed(Egui::KeyCode::Enter),
      Egui::Event.text_input("\r")], 0.048)
    picked2.should eq("Ubuntu Mono")
    ctx2.memory.data.get_string(Egui::Id.from("s2/buf"),
      "<?>").should eq("Ubuntu Mono")
  end

  it "Enter with the list closed commits an exact match" do
    ctx = Egui::Context.new
    picked = ""
    select_frame(ctx, "", "Ubuntu Mono", [] of Egui::Event, 0.016) { |o| picked = o }
    # the buffer names an option exactly, but the field needs focus
    # for the key to be its — focus it first
    select_frame(ctx, "", "Ubuntu Mono",
      [Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032) { |o| picked = o }
    select_frame(ctx, "", "Ubuntu Mono",
      [Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.048) { |o| picked = o }
    picked.should eq("Ubuntu Mono")
    # a buffer matching nothing confirms nothing
    ctx2 = Egui::Context.new
    picked2 = ""
    draw2 = ->(time : Float64, events : Array(Egui::Event)) do
      raw = Egui::RawInput.new(SELECT_SCREEN, events, time)
      ctx2.begin_frame(raw)
      ctx2.central_panel do |ui|
        ui.select_box("s2", "", OPTIONS, 160.0) { |o| picked2 = o }
      end
      ctx2.end_frame
    end
    draw2.call(0.016, [] of Egui::Event)
    draw2.call(0.032, [Egui::Event.key_pressed(Egui::KeyCode::Tab)])
    ctx2.memory.data.set_string(Egui::Id.from("s2/buf"), "nope")
    draw2.call(0.048, [Egui::Event.key_pressed(Egui::KeyCode::Enter)])
    picked2.should eq("")
  end

  # Keyboard walk + wheel: a long list (the gallery's font-size box
  # shape — 23 rows over a 220px viewport).
  it "Down/Up walk the list and Enter confirms the walked row" do
    ctx = Egui::Context.new
    picked = ""
    walk_frame(ctx, "12", [] of Egui::Event, 0.008) { |o| picked = o }
    # focus the field (Tab — the only focusable), then open with Down
    walk_frame(ctx, "12", [Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.016) { |o| picked = o }
    walk_frame(ctx, "12", [] of Egui::Event, 0.032) { |o| picked = o }
    ctx.popup_open?("walk").should be_false # not yet — no key pressed
    walk_frame(ctx, "12", [Egui::Event.key_pressed(Egui::KeyCode::Down)], 0.048) { |o| picked = o }
    ctx.popup_open?("walk").should be_true # Down opened it, walk parked on 12
    # Down ×2: 12 → 13 → 14; Up ×1 → 13; Enter → "13"
    2.times do |i|
      walk_frame(ctx, "12", [Egui::Event.key_pressed(Egui::KeyCode::Down)],
        0.064 + i * 0.016) { |o| picked = o }
    end
    walk_frame(ctx, "12", [Egui::Event.key_pressed(Egui::KeyCode::Up)], 0.096) { |o| picked = o }
    walk_frame(ctx, "12", [Egui::Event.key_pressed(Egui::KeyCode::Enter)], 0.112) { |o| picked = o }
    picked.should eq("13")
    ctx.popup_open?("walk").should be_false
  end

  it "follows the walked row with the list's scroll" do
    ctx = Egui::Context.new
    picked = ""
    walk_frame(ctx, "10", [] of Egui::Event, 0.008) { |o| picked = o }
    walk_frame(ctx, "10", [Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.016) { |o| picked = o }
    walk_frame(ctx, "10", [] of Egui::Event, 0.032) { |o| picked = o }
    # open + walk far past the fold (10 → 20)
    walk_frame(ctx, "10", [Egui::Event.key_pressed(Egui::KeyCode::Down)], 0.048) { |o| picked = o }
    9.times do |i|
      walk_frame(ctx, "10", [Egui::Event.key_pressed(Egui::KeyCode::Down)],
        0.064 + i * 0.016) { |o| picked = o }
    end
    off = ctx.memory.data.get_vec2(Egui::Id.from("walk/list"), Egui::Vec2.zero)
    off.y.should be > 0.0 # the viewport followed the walked row down
  end

  it "scrolls the open list with the mouse wheel" do
    ctx = Egui::Context.new
    picked = ""
    walk_frame(ctx, "12", [] of Egui::Event, 0.008) { |o| picked = o }
    # open via the chevron strip (right edge of the 80px box)
    walk_frame(ctx, "12",
      [Egui::Event.pointer_pressed(Egui::Pos2.new(70.0, 20.0)),
       Egui::Event.pointer_released(Egui::Pos2.new(70.0, 20.0))],
      0.016) { |o| picked = o }
    walk_frame(ctx, "12", [] of Egui::Event, 0.032) { |o| picked = o }
    ctx.popup_open?("walk").should be_true
    # wheel down over the list (pointer inside the popup viewport)
    walk_frame(ctx, "12",
      [Egui::Event.pointer_moved(Egui::Pos2.new(40.0, 100.0)),
       Egui::Event.scroll(Egui::Vec2.new(0.0, 3.0))], 0.048) { |o| picked = o }
    off = ctx.memory.data.get_vec2(Egui::Id.from("walk/list"), Egui::Vec2.zero)
    off.y.should be > 0.0
  end

  it "keeps a SEARCH-driven scroll: the follow must not snap back to the top" do
    ctx = Egui::Context.new
    picked = ""
    walk_frame(ctx, "10", [] of Egui::Event, 0.008) { |o| picked = o }
    # click into the field (select-all on entry), then type a filter
    # leaving a scrollable list ("1" → 10..19, 21, 31 = 12 rows)
    walk_frame(ctx, "10",
      [Egui::Event.pointer_pressed(Egui::Pos2.new(40.0, 20.0)),
       Egui::Event.pointer_released(Egui::Pos2.new(40.0, 20.0))],
      0.016) { |o| picked = o }
    walk_frame(ctx, "10", [Egui::Event.text_input("1")], 0.032) { |o| picked = o }
    ctx.popup_open?("walk").should be_true
    # wheel down over the filtered list…
    walk_frame(ctx, "10",
      [Egui::Event.pointer_moved(Egui::Pos2.new(40.0, 100.0)),
       Egui::Event.scroll(Egui::Vec2.new(0.0, 3.0))], 0.048) { |o| picked = o }
    scrolled = ctx.memory.data.get_vec2(Egui::Id.from("walk/list"),
      Egui::Vec2.zero).y
    scrolled.should be > 0.0
    # …and the offset must SURVIVE later frames: the Enter candidate
    # (row 0) may sit above the fold — the follow logic must not yank
    # the viewport back to it once the user moved it.
    3.times do |i|
      walk_frame(ctx, "10", [] of Egui::Event, 0.064 + i * 0.016) { |o| picked = o }
    end
    kept = ctx.memory.data.get_vec2(Egui::Id.from("walk/list"),
      Egui::Vec2.zero).y
    kept.should be > 0.0
  end

  it "clamps a stale anchor when the buffer shrinks (SelectBox pick path)" do
    ctx = Egui::Context.new
    buf = ""
    draw = ->(events : Array(Egui::Event), time : Float64) do
      raw = Egui::RawInput.new(SELECT_SCREEN, events, time)
      ctx.begin_frame(raw)
      ctx.central_panel do |ui|
        ui.text_edit_singleline(buf) { |t| buf = t }
      end
      ctx.end_frame
    end
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032) # focus
    "abcdef".each_char_with_index do |ch, i|
      draw.call([Egui::Event.text_input(ch.to_s)], 0.048 + i * 0.016)
    end
    # Shift+Home: cursor 0, anchor 6 — stored past the shrunken buffer
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Home,
      modifiers: Egui::Modifiers.new(shift: true))], 0.160)
    # the app swaps the buffer for a shorter one (what a SelectBox
    # pick does to its field)…
    buf = ""
    # …and the next typed character must not index past the string
    draw.call([Egui::Event.text_input("x")], 0.176)
    buf.should eq("x")
  end
end
