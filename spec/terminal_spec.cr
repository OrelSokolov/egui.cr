# Terminal emulator core specs: VT parser, grid/scrollback, modes,
# selection, keymap encoding. Pure headless — no PTY, no backend.

require "spec"
require "../src/egui"

def term(cols = 10, rows = 4, scrollback = 100)
  Egui::Terminal::Terminal.new(cols, rows, scrollback)
end

def row_text(t : Egui::Terminal::Terminal, y)
  t.grid.line_text(y)
end

def term_mods(ctrl = false, shift = false, alt = false)
  Egui::Modifiers.new(ctrl: ctrl, shift: shift, alt: alt)
end


describe Egui::Terminal::Terminal do
  it "prints plain text and tracks the cursor" do
    t = term
    t.feed("hi")
    row_text(t, 0).should eq("hi")
    t.cursor_x.should eq(2)
    t.cursor_y.should eq(0)
  end

  it "handles CR/LF and scrolling at the bottom" do
    t = term(rows: 2)
    t.feed("one\r\ntwo\r\nthree")
    row_text(t, 0).should eq("two")
    row_text(t, 1).should eq("three")
    t.grid.scrollback_used.should eq(1)
    t.grid.line(0).should_not be_nil
    # the scrolled-out line is in the scrollback
    (t.grid.lines[0].map(&.char).join.rstrip).should eq("one")
  end

  it "decodes UTF-8 and wide chars" do
    t = term(cols: 10)
    t.feed("привет")
    row_text(t, 0).should eq("привет")
    t.feed("\r\n漢字")
    row_text(t, 1).should eq("漢字")
    # 漢 occupies two cells: cursor advanced by 4 for two wide chars
    t.cursor_x.should eq(4)
  end

  it "parses SGR colors (16/256/RGB + attributes)" do
    t = term
    t.feed("\e[1;31mred\e[0m plain")
    cells = t.grid.line(0)
    cells[0].fg.should eq(Egui::Terminal::TermColor.indexed(1))
    cells[0].attrs?(Egui::Terminal::Cell::BOLD).should be_true
    cells[4].fg.should eq(Egui::Terminal::TermColor.default_fg)
    cells[4].attrs?(Egui::Terminal::Cell::BOLD).should be_false

    t.feed("\e[38;5;196mX\e[38;2;10;20;30mY")
    cells = t.grid.line(0)
    cells[9].fg.should eq(Egui::Terminal::TermColor.indexed(196))
    # Y does not fit on the wrapped row — it lands on row 1
    t.grid.line(1)[0].fg.should eq(Egui::Terminal::TermColor.rgb(10, 20, 30))
  end

  it "applies background color erase to EL/ED" do
    t = term(cols: 10, rows: 2)
    t.feed("\e[44m     x\e[K")
    cells = t.grid.line(0)
    # everything from the cursor to the line end is erased with pen bg
    cells[9].bg.should eq(Egui::Terminal::TermColor.indexed(4))
    row_text(t, 0).should eq("     x")
  end

  it "moves the cursor with CUP/CUD/CUF and clamps" do
    t = term(cols = 10, rows = 5)
    t.feed("\e[3;5H")
    t.cursor_y.should eq(2)
    t.cursor_x.should eq(4)
    t.feed("\e[2A")
    t.cursor_y.should eq(0)
    t.feed("\e[99B")
    t.cursor_y.should eq(4)
    t.feed("\e[10D")
    t.cursor_x.should eq(0)
  end

  it "wraps long lines with a pending-wrap column" do
    t = term(cols: 5, rows: 4)
    t.feed("abcde") # fills row 0, cursor parked at last col
    t.cursor_x.should eq(4)
    t.cursor_y.should eq(0)
    t.feed("f") # wraps to row 1
    t.cursor_y.should eq(1)
    row_text(t, 1).should eq("f")
  end

  it "inserts and deletes lines within the scroll region" do
    t = term(cols: 4, rows: 4)
    t.feed("aa\r\nbb\r\ncc\r\ndd")
    t.feed("\e[2;1H\e[2L") # at row 2: insert 2 lines
    row_text(t, 1).should eq("")
    row_text(t, 2).should eq("")
    row_text(t, 3).should eq("bb") # cc/dd pushed down, dd scrolled off region
  end

  it "switches to the alternate screen and back, preserving the primary" do
    t = term(cols: 8, rows: 3)
    t.feed("primary")
    t.feed("\e[?1049h")
    t.alt_active?.should be_true
    t.current_grid.line_text(0).should eq("") # alt screen starts clear
    t.feed("ALT")
    t.feed("\e[?1049l")
    t.alt_active?.should be_false
    row_text(t, 0).should eq("primary")
  end

  it "reports the cursor position (DSR 6n) and DA" do
    t = term
    t.feed("\e[2;3H\e[6n\e[c")
    String.new(t.drain_output.not_nil!).should eq("\e[2;3R\e[?6c")
  end

  it "parses OSC title changes" do
    t = term
    t.feed("hello\e]0;my title\ahello")
    t.title.should eq("my title")
  end

  it "supports DEC line drawing (ESC ( 0)" do
    t = term
    t.feed("\e(0lqk\e(B")
    cells = t.grid.line(0)
    cells[0].char.should eq('┌')
    cells[1].char.should eq('─')
    cells[2].char.should eq('┐')
  end

  it "sets and honors scroll regions (DECSTBM)" do
    t = term(cols: 4, rows: 4)
    t.feed("aa\r\nbb\r\ncc\r\ndd")
    t.feed("\e[2;3r")   # region rows 2..3
    t.feed("\e[3;1H\n") # LF at region bottom scrolls only the region
    row_text(t, 0).should eq("aa")
    row_text(t, 1).should eq("cc")
    row_text(t, 2).should eq("")
    row_text(t, 3).should eq("dd")
  end

  it "keeps scrollback bounded and exposes display scrolling" do
    t = term(cols: 4, rows: 2, scrollback: 5)
    20.times { |i| t.feed("l#{sprintf("%02d", i)}\r\n") }
    t.grid.scrollback_used.should eq(5)
    t.scroll_display(5)
    t.display_offset.should eq(5)
    t.scroll_display(-2)
    t.display_offset.should eq(3)
    t.scroll_display(100)
    t.display_offset.should eq(5)
  end

  it "extracts selection text spanning lines" do
    t = term(cols: 20, rows: 4)
    t.feed("hello world\r\nsecond line")
    grid = t.grid
    t.selection = {Egui::Terminal::Terminal::SelPoint.new(grid.line_index(0), 6),
                   Egui::Terminal::Terminal::SelPoint.new(grid.line_index(1), 6)}
    t.selection_text.should eq("world\nsecond")
  end

  it "erases lines and the display (EL/ED variants)" do
    t = term(cols: 8, rows: 2)
    t.feed("abcdef\r\nghijkl")
    t.feed("\e[1;3H\e[K")  # erase from col 3 to end of line 1
    row_text(t, 0).should eq("ab")
    row_text(t, 1).should eq("ghijkl")
    t.feed("\e[2J")
    row_text(t, 0).should eq("")
    row_text(t, 1).should eq("")
  end

  it "resizes keeping content bottom-anchored" do
    t = term(cols: 8, rows: 3)
    t.feed("aa\r\nbb\r\ncc")
    t.resize(8, 2)
    row_text(t, 0).should eq("bb")
    row_text(t, 1).should eq("cc")
    t.grid.scrollback_used.should eq(1)
    t.resize(8, 3) # growing pulls the history back
    row_text(t, 0).should eq("aa")
  end

  it "grows with empty history like xterm: content stays put, blanks pad the bottom" do
    t = term(cols: 8, rows: 3)
    t.feed("prompt>") # row 0, the fresh-screen case (GUI first frame)
    t.resize(20, 10)
    t.cursor_y.should eq(0) # cursor did NOT slide down
    row_text(t, 0).should eq("prompt>") # prompt still on row 0
    t.feed(" ok")
    row_text(t, 0).should eq("prompt> ok")
  end

  it "replies to window size queries (CSI 18 t)" do
    t = term(cols: 17, rows: 9)
    t.feed("\e[18t")
    String.new(t.drain_output.not_nil!).should eq("\e[8;9;17t")
  end
end

describe Egui::Terminal::Keymap do

  it "passes plain text through" do
    t = term
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::A, term_mods, "a").should eq(Bytes['a'.ord])
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::A, term_mods(shift: true), "A").should eq(Bytes['A'.ord])
  end

  it "encodes Ctrl+letter as C0" do
    t = term
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::C, term_mods(ctrl: true), nil).should eq(Bytes[3])
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Z, term_mods(ctrl: true), nil).should eq(Bytes[26])
  end

  it "prefixes Alt with ESC" do
    t = term
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::B, term_mods(alt: true), "b").should eq(Bytes[0x1b, 'b'.ord])
  end

  it "uses SS3 arrows in application cursor mode" do
    t = term
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Up, term_mods, nil).should eq("\e[A".to_slice)
    t.feed("\e[?1h")
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Up, term_mods, nil).should eq("\eOA".to_slice)
  end

  it "adds the xterm modifier parameter" do
    t = term
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Up, term_mods(ctrl: true), nil).should eq("\e[1;5A".to_slice)
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Delete, term_mods(shift: true), nil).should eq("\e[3;2~".to_slice)
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::F5, term_mods, nil).should eq("\e[15~".to_slice)
  end

  it "encodes Enter/Tab/Backspace/Escape" do
    t = term
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Enter, term_mods, nil).should eq(Bytes[0x0d])
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Tab, term_mods, nil).should eq(Bytes[0x09])
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Backspace, term_mods, nil).should eq(Bytes[0x7f])
    Egui::Terminal::Keymap.encode(t, Egui::KeyCode::Escape, term_mods, nil).should eq(Bytes[0x1b])
  end

  it "wraps pastes in brackets when DECSET 2004 is on" do
    t = term
    t.paste_bytes("ls\r\n-l").should eq("ls\r-l".to_slice)
    t.feed("\e[?2004h")
    t.paste_bytes("ls -l").should eq("\e[200~ls -l\e[201~".to_slice)
  end

  it "encodes SGR mouse reports" do
    t = term
    t.feed("\e[?1000h\e[?1006h")
    t.mouse_bytes(0, true, 2, 3).should eq("\e[<0;3;4M".to_slice)
    t.mouse_bytes(0, false, 2, 3).should eq("\e[<0;3;4m".to_slice)
  end
end

describe Egui::Terminal::Parser do
  it "survives malformed sequences without corrupting output" do
    t = term(cols: 30)
    t.feed("a\e[999999999999mb\e[;m c\eX\e]0;broken")
    row_text(t, 0).should contain("ab c")
  end

  it "continues text after an aborted OSC" do
    t = term(cols: 30)
    t.feed("\e]2;t\x18ok") # CAN aborts the OSC
    row_text(t, 0).should eq("ok")
  end
end
