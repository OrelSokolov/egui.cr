require "spec"
require "../src/egui"

VSCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def raw_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event, time : Float64 = 0.016)
  raw = Egui::RawInput.new(VSCREEN, events, time)
  ctx.begin_frame(raw)
end

describe Egui::TextArea do
  describe "line index (virtual big-text mode)" do
    it "maps every character offset to a line start" do
      text = "ab\ncd\n\nxyz"
      starts = Egui::TextArea.line_char_starts(text)
      # "ab" (0..2), "cd" (3..5), "" (6), "xyz" (7..10): line starts
      # 0, 3, 6, 7 — the trailing entry 10 is the buffer end.
      # lines: "ab", "cd", "", "xyz" — no trailing entry: the last
      # line's end is the buffer size.
      starts.should eq([0, 3, 6, 7])

      Egui::TextArea.line_of(starts, 0).should eq(0)
      Egui::TextArea.line_of(starts, 2).should eq(0)
      Egui::TextArea.line_of(starts, 3).should eq(1)
      Egui::TextArea.line_of(starts, 5).should eq(1)
      Egui::TextArea.line_of(starts, 6).should eq(2) # empty line
      Egui::TextArea.line_of(starts, 7).should eq(3)
      Egui::TextArea.line_of(starts, 10).should eq(3)
    end

    it "counts characters, not bytes (UTF-8)" do
      text = "ёжик\nz\n"
      starts = Egui::TextArea.line_char_starts(text)
      # ё ж и к = 4 chars, so line 1 starts at char 5 (after \n), line
      # 2 (after "z\n") at 7; bytesize is 10 — a byte-wise count would
      # say 9 and 11.
      starts.should eq([0, 5, 7])
    end

    it "treats a trailing newline as a phantom empty line" do
      Egui::TextArea.line_char_starts("a\nb\n").should eq([0, 2, 4])
      Egui::TextArea.line_char_starts("a\nb").should eq([0, 2])
    end
  end

  it "runs a frame over a big buffer without wrapping it whole" do
    ctx = Egui::Context.new
    line = "the quick brown fox jumps over the lazy dog\n"
    big = line * 15_000 # ~630 KiB > BIG_TEXT_BYTES
    text_out = nil
    3.times do
      raw_frame(ctx)
      ctx.central_panel do |ui|
        resp = ui.textarea(big, rows: 20) { |_t| }
        text_out = resp.widget_text
      end
      ctx.end_frame
    end
    text_out.should eq(big)
  end
end

describe "textarea big-buffer scrolling" do
  it "wheel-scrolling away from the caret is not snapped back (recenter is nav-key gated)" do
    ctx = Egui::Context.new
    line = "the quick brown fox jumps over the lazy dog\n"
    big = line * 15_000 # ~630 KiB > BIG_TEXT_BYTES
    cur = big

    run = ->(events : Array(Egui::Event), time : Float64) do
      ctx.begin_frame(Egui::RawInput.new(VSCREEN, events, time))
      ctx.central_panel do |ui|
        ui.textarea(big, rows: 20) { |_t| }
      end
      ctx.end_frame
    end

    # Park the pointer inside the editor and click to focus (caret
    # lands mid-file window, line ~13).
    run.call([Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 300.0))], 0.02)
    run.call([Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))], 0.04)
    run.call([Egui::Event.pointer_released(Egui::Pos2.new(400.0, 300.0))], 0.06)

    # Wheel-scroll far away from the caret, no navigation keys.
    40.times do |i|
      run.call([Egui::Event.scroll(Egui::Vec2.new(0.0, 120.0)),
                Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 300.0))],
        0.1 + i * 0.016)
    end

    scroll_ids = ctx.memory.scroll_rects.keys
    scroll_ids.size.should be > 0
    offset = scroll_ids.map { |sid| ctx.memory.data.get_vec2(sid, Egui::Vec2.zero).y }.max
    # The caret sits near line 13 (~270px): without the fix the offset
    # snaps back there every frame; a real scroll must run far past it.
    offset.should be > 2000.0
  end
end

describe "textarea big-buffer document jumps" do
  it "Ctrl+End puts the caret at the end and scrolls the viewport there" do
    ctx = Egui::Context.new
    line = "the quick brown fox jumps over the lazy dog\n"
    big = line * 15_000 # ~630 KiB > BIG_TEXT_BYTES
    ctrl = Egui::Modifiers.new(ctrl: true)

    run = ->(events : Array(Egui::Event), time : Float64) do
      ctx.begin_frame(Egui::RawInput.new(VSCREEN, events, time))
      ctx.central_panel { |ui| ui.textarea(big, rows: 20) { |_t| } }
      ctx.end_frame
    end

    # Focus mid-file (virtual mode defaults the caret to the top; a
    # click lands it in view), then jump to the document end.
    run.call([Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 300.0))], 0.02)
    run.call([Egui::Event.pointer_pressed(Egui::Pos2.new(400.0, 300.0))], 0.04)
    run.call([Egui::Event.pointer_released(Egui::Pos2.new(400.0, 300.0))], 0.06)
    run.call([Egui::Event.key_pressed(Egui::KeyCode::End, ctrl)], 0.08)
    run.call([Egui::Event.key_released(Egui::KeyCode::End)], 0.09)
    run.call([] of Egui::Event, 0.10)

    offset = ctx.memory.scroll_rects.keys
      .map { |sid| ctx.memory.data.get_vec2(sid, Egui::Vec2.zero).y }.max
    # 15001 lines × ~20.8px ≈ 312k of content: the follow-caret scroll
    # must have moved the viewport deep into the file, not stayed at
    # the click (~300px) or the top.
    offset.should be > 250_000.0
  end
end
