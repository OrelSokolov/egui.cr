# Opt-in vim-style BLOCK caret (`cursor_style: :block`) in TextEdit
# and TextArea: the caret is a filled rect covering the character
# cell, with the character under it re-drawn in the widget's
# background (inverse video). The DEFAULT (:line) stays a 1px line —
# notepad and the standard fields must not change appearance.
require "spec"
require "../src/egui"

BC_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def bc_frame(ctx : Egui::Context, events : Array(Egui::Event), time : Float64, & : Egui::Ui -> Nil)
  ctx.begin_frame(Egui::RawInput.new(BC_SCREEN, events, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), BC_SCREEN)
  yield ui
  ctx.end_frame
end

describe "block caret" do
  it "TextEdit defaults to a line caret" do
    ctx = Egui::Context.new
    id = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      bc_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new("hello"))
        id = r.id
      end
    end
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true

    ctx.painter.commands.select(Egui::LineCmd)
        .count { |l| l.p1.x == l.p2.x }.should eq(1)
  end

  it "TextEdit :block draws a cell and inverts the char under it" do
    ctx = Egui::Context.new
    id = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      bc_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new("hello", cursor_style: :block))
        id = r.id
      end
    end
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true

    # Caret at the end of "hello" (past the last char): a block with a
    # space-width fallback cell, and no 1px vertical caret line.
    ctx.painter.commands.select(Egui::LineCmd)
        .select { |l| l.p1.x == l.p2.x }.should be_empty
    rects = ctx.painter.commands.select(Egui::RectCmd)
        .select { |c| c.fill && !c.stroke_color &&
                       c.rect.width > 3.0 && c.rect.width < 60.0 &&
                       c.rect.height > 8.0 }
    rects.should_not be_empty
    caret = rects.first
    caret.rect.width.should be > 3.0 # a cell, not a hairline
    caret.rect.height.should be > 8.0

    # Home: the block covers 'h', which is re-painted over the block
    # fill (the galley run draws "hello" whole, so the standalone "h"
    # TextCmd IS the inverted repaint).
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Home)], 0.064)
    ctx.painter.commands.select(Egui::TextCmd)
        .count(&.text.==("h")).should eq(1)
  end

  it "TextArea :block draws a cell and inverts the char under it" do
    ctx = Egui::Context.new
    id = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      bc_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextArea.new("ab\ncd", cursor_style: :block))
        id = r.id
      end
    end
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.048)
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true

    ctx.painter.commands.select(Egui::LineCmd)
        .select { |l| l.p1.x == l.p2.x }.should be_empty
    rects = ctx.painter.commands.select(Egui::RectCmd)
        .select { |c| c.fill && !c.stroke_color &&
                       c.rect.width > 3.0 && c.rect.width < 60.0 &&
                       c.rect.height > 8.0 }
    rects.should_not be_empty
    caret = rects.first
    caret.rect.width.should be > 3.0
    caret.rect.height.should be > 8.0

    # Home on the LAST line ("cd"): the block covers 'c', re-painted
    # inverted over the fill (the galley runs draw whole rows).
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Home)], 0.064)
    ctx.painter.commands.select(Egui::TextCmd)
        .count(&.text.==("c")).should eq(1)
  end
end

# `cursor_blinks: false` holds the caret STEADY: the default caret
# hides during the blink-off phase ((time % 1.0) >= 0.6), a steady one
# stays drawn at the same timestamps.
describe "cursor blink option" do
  it "TextEdit default caret hides in the blink-off phase" do
    ctx = Egui::Context.new
    id = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      bc_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new("hello"))
        id = r.id
      end
    end
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.8) # blink-off phase
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true
    ctx.painter.commands.select(Egui::LineCmd)
        .select { |l| l.p1.x == l.p2.x }.should be_empty
  end

  it "TextEdit cursor_blinks: false holds the caret steady" do
    ctx = Egui::Context.new
    id = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      bc_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextEdit.new("hello", cursor_blinks: false))
        id = r.id
      end
    end
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.8) # blink-off phase — still drawn
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true
    ctx.painter.commands.select(Egui::LineCmd)
        .count { |l| l.p1.x == l.p2.x }.should eq(1)
  end

  it "TextArea cursor_blinks: false holds the caret steady" do
    ctx = Egui::Context.new
    id = nil
    draw = ->(events : Array(Egui::Event), time : Float64) do
      bc_frame(ctx, events, time) do |ui|
        r = ui.add(Egui::TextArea.new("ab\ncd", cursor_blinks: false))
        id = r.id
      end
    end
    draw.call([] of Egui::Event, 0.016)
    draw.call([Egui::Event.key_pressed(Egui::KeyCode::Tab)], 0.032)
    draw.call([] of Egui::Event, 0.8) # blink-off phase — still drawn
    ctx.memory.focus.has_focus?(id.not_nil!).should be_true
    ctx.painter.commands.select(Egui::LineCmd)
        .count { |l| l.p1.x == l.p2.x }.should eq(1)
  end
end

