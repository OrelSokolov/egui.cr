# TermView widget specs: headless frame-driving of the widget against
# a fake backend — the paint pipeline (backgrounds, text runs, cursor)
# and the input path (keys → PTY bytes, wheel, resize) without a GPU.

require "spec"
require "../src/egui"

TERM_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

class FakeBackend < Egui::Terminal::Backend
  getter term : Egui::Terminal::Terminal
  property resized = [] of {Int32, Int32}
  property written = [] of Bytes
  property pump_count = 0
  property dead = false

  def initialize(@term : Egui::Terminal::Terminal)
  end

  def self.with_screen(text : String) : FakeBackend
    new(Egui::Terminal::Terminal.new(20, 5).tap(&.feed(text)))
  end

  def pump : Bool
    @pump_count += 1
    false
  end

  def write(bytes : Bytes) : Nil
    @written << bytes
  end

  def resize(cols : Int32, rows : Int32) : Nil
    @resized << {cols, rows}
    @term.resize(cols, rows)
  end

  def alive? : Bool
    !@dead
  end

  def exit_code : Int32?
    0
  end

  def close : Nil
  end
end

def term_frame(ctx : Egui::Context, backend : FakeBackend,
               events : Array(Egui::Event) = [] of Egui::Event,
               time : Float64 = 0.016)
  raw = Egui::RawInput.new(TERM_SCREEN, events, time)
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    ui.terminal(backend)
  end
  ctx.end_frame
end

describe Egui::Terminal::TermView do
  it "paints background, text runs and the cursor" do
    backend = FakeBackend.with_screen("hello $ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend)

    texts = ctx.painter.commands.select(Egui::TextCmd)
    texts.map(&.text).join.should contain("hello")

    rects = ctx.painter.commands.select(Egui::RectCmd)
    # the terminal background rect covers the whole panel area
    bg = rects.max_by { |r| r.rect.width * r.rect.height }
    bg.rect.width.should be > 700
  end

  it "paints REVERSE text with a swapped background (bracketed-paste echo)" do
    backend = FakeBackend.with_screen("$ \e[7mZZ42\e[27m")
    ctx = Egui::Context.new
    term_frame(ctx, backend)

    theme = Egui::Terminal::Theme.new
    # glyphs draw in the BACKGROUND color (dark on the bright fill)…
    ctx.painter.commands.select(Egui::TextCmd)
        .find { |c| c.text == "ZZ42" }.not_nil!
        .color.should eq(theme.background)
    # …over a foreground-colored background run (no dark-on-dark)
    ctx.painter.commands.select(Egui::RectCmd)
        .any? { |c| c.fill == theme.foreground }.should be_true
  end

  it "resizes the session to whole cells fitting the rect" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend)
    backend.resized.size.should eq(1)
    cols, rows = backend.resized.first
    cols.should be > 40
    rows.should be > 10
  end

  it "sends typed text to the backend" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    # first frame: the terminal exists but is not focused yet
    term_frame(ctx, backend)

    click = Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))
    term_frame(ctx, backend, [click])

    type_a = Egui::Event.key_pressed(Egui::KeyCode::A)
    term_frame(ctx, backend, [type_a, Egui::Event.text_input("a")])

    joined = backend.written.map { |b| String.new(b) }.join
    joined.should contain("a")
  end

  it "sends arrow keys as CSI sequences" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend)
    click = Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))
    term_frame(ctx, backend, [click])
    term_frame(ctx, backend, [Egui::Event.key_pressed(Egui::KeyCode::Up)])

    joined = backend.written.map { |b| String.new(b) }.join
    joined.should contain("\e[A")
  end

  it "sends Enter as CR and Backspace as DEL" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend)
    click = Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))
    term_frame(ctx, backend, [click])
    # sapp delivers Enter/Backspace as KEY_DOWN only (no CHAR event),
    # so these must ride the special-key path.
    term_frame(ctx, backend, [Egui::Event.key_pressed(Egui::KeyCode::Enter)])
    term_frame(ctx, backend, [Egui::Event.key_pressed(Egui::KeyCode::Backspace)])

    joined = backend.written.map { |b| String.new(b) }.join
    joined.should contain("\r")
    joined.should contain("\u{7f}")
  end

  it "keeps Tab in the focused terminal (keyboard lock, no focus cycling)" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend)
    click = Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))
    term_frame(ctx, backend, [click])
    term_frame(ctx, backend) # focus settles; the terminal latches the lock
    focused = ctx.memory.focus.id
    focused.should_not be_nil

    term_frame(ctx, backend, [Egui::Event.key_pressed(Egui::KeyCode::Tab)])

    joined = backend.written.map { |b| String.new(b) }.join
    joined.should contain("\t")
    ctx.memory.focus.id.should eq(focused) # focus navigation stood down
  end

  it "scrolls the scrollback on wheel without mouse reporting" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend) # resize settles first
    click = Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))
    term_frame(ctx, backend, [click])

    rows = backend.term.rows
    (rows + 3).times { backend.term.feed("\e[#{rows};1H\n") } # push to history
    backend.term.display_offset.should eq(0)

    wheel_up = Egui::Event.scroll(Egui::Vec2.new(0.0, 120.0))
    term_frame(ctx, backend, [wheel_up])
    backend.term.display_offset.should be > 0
  end

  it "paints a scrollbar once scrollback exists" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend) # no history yet: no bar
    ctx.painter.commands.select(Egui::RectCmd)
        .none? { |c| c.rect.width <= Egui::Terminal::TermView::BAR_W &&
                      c.rect.height > 100 }
        .should be_true

    rows = backend.term.rows
    (rows * 3).times { backend.term.feed("\e[#{rows};1H\n") }
    term_frame(ctx, backend)
    bars = ctx.painter.commands.select(Egui::RectCmd)
                   .select { |c| c.rect.width == Egui::Terminal::TermView::BAR_W }
    # track + thumb, hugging the panel's right edge
    bars.size.should eq(2)
    bars.each { |c| c.rect.right.should be > TERM_SCREEN.width - 40 }
  end

  it "drags the scrollbar thumb to an absolute position" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend) # resize settles, bar registers its rect

    rows = backend.term.rows
    (rows * 3).times { backend.term.feed("\e[#{rows};1H\n") }
    term_frame(ctx, backend) # bar painted; press targets hit-test it
    track = ctx.painter.commands.select(Egui::RectCmd)
                  .find { |c| c.rect.width <= Egui::Terminal::TermView::BAR_W &&
                                c.rect.height > 100 }
                  .not_nil!.rect

    # press near the track top (thumb sits at the bottom while live),
    # then drag past the click threshold
    press = Egui::Pos2.new(track.min.x + 5, track.min.y + 5)
    term_frame(ctx, backend, [Egui::Event.pointer_pressed(press)])
    term_frame(ctx, backend,
      [Egui::Event.pointer_moved(Egui::Pos2.new(press.x, press.y + 40))])

    used = backend.term.grid.scrollback_used
    backend.term.display_offset.should be > used // 2
  end

  it "pages toward a plain click on the scrollbar track" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend)

    rows = backend.term.rows
    (rows * 3).times { backend.term.feed("\e[#{rows};1H\n") }
    term_frame(ctx, backend)
    track = ctx.painter.commands.select(Egui::RectCmd)
                  .find { |c| c.rect.width <= Egui::Terminal::TermView::BAR_W &&
                                c.rect.height > 100 }
                  .not_nil!.rect

    above = Egui::Pos2.new(track.min.x + 5, track.min.y + 5)
    term_frame(ctx, backend, [Egui::Event.pointer_pressed(above)])
    term_frame(ctx, backend, [Egui::Event.pointer_released(above)])

    backend.term.display_offset.should eq(rows) # exactly one page up
  end

  it "drag-selects cells and clears on a plain click" do
    backend = FakeBackend.with_screen("abcdefghijklmnopqrstuvwxyz")
    ctx = Egui::Context.new
    term_frame(ctx, backend)
    term_frame(ctx, backend) # rects registered for hit-testing

    term_frame(ctx, backend,
      [Egui::Event.pointer_pressed(Egui::Pos2.new(60.0, 20.0))], time: 0.10)
    term_frame(ctx, backend,
      [Egui::Event.pointer_moved(Egui::Pos2.new(200.0, 20.0))], time: 0.12)
    term_frame(ctx, backend,
      [Egui::Event.pointer_released(Egui::Pos2.new(200.0, 20.0))], time: 0.14)

    term = backend.term
    sel = term.selection.should_not be_nil
    a, b = sel.not_nil!
    b.col.should be > a.col # the head followed the drag
    # the text matches the grid content between the endpoints
    cells = term.grid.lines[a.line].to_a
    expected = cells[a.col...b.col].to_a.map(&.char).join.rstrip
    term.selection_text.should eq(expected)
    # the overlay is painted over the selected cells
    overlay = Egui::Terminal::Theme.new.selection_overlay
    ctx.painter.commands.select(Egui::RectCmd)
        .any? { |c| c.fill == overlay }.should be_true

    # a plain click (no drag) clears the selection
    term_frame(ctx, backend,
      [Egui::Event.pointer_pressed(Egui::Pos2.new(60.0, 20.0))], time: 0.20)
    term_frame(ctx, backend,
      [Egui::Event.pointer_released(Egui::Pos2.new(60.0, 20.0))], time: 0.22)
    term.selection.should be_nil
  end

  it "double-click selects a word, triple-click the line" do
    backend = FakeBackend.with_screen("word word word")
    ctx = Egui::Context.new
    term_frame(ctx, backend)
    term_frame(ctx, backend)

    pos = Egui::Pos2.new(60.0, 20.0) # row 0, inside a word
    term_frame(ctx, backend, [Egui::Event.pointer_pressed(pos)], time: 0.10)
    term_frame(ctx, backend, [Egui::Event.pointer_released(pos)], time: 0.11)
    term_frame(ctx, backend, [Egui::Event.pointer_pressed(pos)], time: 0.20)
    term_frame(ctx, backend, [Egui::Event.pointer_released(pos)], time: 0.21)
    backend.term.selection_text.should eq("word")

    # the third click in the series selects the whole line
    term_frame(ctx, backend, [Egui::Event.pointer_pressed(pos)], time: 0.26)
    term_frame(ctx, backend, [Egui::Event.pointer_released(pos)], time: 0.27)
    backend.term.selection_text.should eq("word word word")
  end

  it "scrolls a page on Ctrl+Shift+PageUp and jumps on Shift+Home" do
    backend = FakeBackend.with_screen("$ ")
    ctx = Egui::Context.new
    term_frame(ctx, backend)
    click = Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))
    term_frame(ctx, backend, [click])
    term_frame(ctx, backend) # focus settles

    rows = backend.term.rows
    (rows * 3).times { backend.term.feed("\e[#{rows};1H\n") }

    ctrl_shift_pgup = Egui::Event.key_pressed(Egui::KeyCode::PageUp,
      Egui::Modifiers.new(ctrl: true, shift: true))
    term_frame(ctx, backend, [ctrl_shift_pgup])
    backend.term.display_offset.should eq(rows)

    shift_home = Egui::Event.key_pressed(Egui::KeyCode::Home,
      Egui::Modifiers.new(shift: true))
    term_frame(ctx, backend, [shift_home])
    backend.term.display_offset.should eq(backend.term.grid.scrollback_used)

    shift_end = Egui::Event.key_pressed(Egui::KeyCode::End,
      Egui::Modifiers.new(shift: true))
    term_frame(ctx, backend, [shift_end])
    backend.term.display_offset.should eq(0)
  end
end
