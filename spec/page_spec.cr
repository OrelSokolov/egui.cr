# Page specs: the full-window page container (Win11 Notepad
# settings-page idiom) — it claims the whole remainder below the
# caption, covers everything else, draws the header (round back
# button + title) without a stroked frame, and fires on_back on
# click. Navigation stays the app's business — the page renders
# whatever it is asked for.

require "spec"
require "../src/egui"

PAGE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def page_frame(ctx : Egui::Context, events : Array(Egui::Event),
               time : Float64, chrome : Bool = false,
               on_back : (-> Nil)? = nil,
               &content : Egui::Ui ->) : Egui::Rect
  raw = Egui::RawInput.new(PAGE_SCREEN, events, time)
  ctx.begin_frame(raw)
  if chrome
    Egui::WindowFrame.show(ctx, "t", Egui::WindowFrame::Style::Windows)
  end
  rect = ctx.page("p", title: "Settings", on_back: on_back) do |ui|
    content.call(ui)
  end
  ctx.end_frame
  rect
end

describe Egui::Page do
  it "claims the whole remainder — all of it without chrome, below the caption with chrome" do
    ctx = Egui::Context.new
    rect = page_frame(ctx, [] of Egui::Event, 0.016) { |ui| }
    rect.top.should eq(0.0)
    rect.size.should eq(PAGE_SCREEN.size)

    ctx2 = Egui::Context.new
    rect2 = page_frame(ctx2, [] of Egui::Event, 0.032, chrome: true) { |ui| }
    rect2.top.should eq(Egui::WindowFrame::Windows::CAPTION_H)
    rect2.height.should eq(600.0 - Egui::WindowFrame::Windows::CAPTION_H)
  end

  it "paints an opaque stroke-free surface and bites the remainder" do
    ctx = Egui::Context.new
    rect = page_frame(ctx, [] of Egui::Event, 0.016) { |ui| }
    surface = ctx.painter.commands.select(Egui::RectCmd)
      .find { |c| c.fill == ctx.style.visuals.panel_fill }
    surface.should_not be_nil
    surface.not_nil!.rect.size.should eq(PAGE_SCREEN.size)
    surface.not_nil!.stroke_color.should be_nil

    # everything after the page gets an empty remainder
    ctx.available_rect.height.should be <= 0.0
  end

  it "the back button fires on_back exactly once on click" do
    fired = 0
    back = -> { fired += 1; nil }
    ctx = Egui::Context.new
    page_frame(ctx, [] of Egui::Event, 0.016, on_back: back) { |ui| }

    # the round button: 8pt inset, 32pt box, centered in the 44pt header
    pos = Egui::Pos2.new(
      Egui::Page::BACK_PAD + Egui::Page::BACK_D / 2.0,
      Egui::Page::HEADER_H / 2.0)
    page_frame(ctx, [Egui::Event.pointer_pressed(pos)], 0.032,
      on_back: back) { |ui| }
    page_frame(ctx, [Egui::Event.pointer_released(pos)], 0.048,
      on_back: back) { |ui| }
    fired.should eq(1)
  end

  it "content runs below the header; no header without title/on_back" do
    ctx = Egui::Context.new
    cursor_y = 0.0
    page_frame(ctx, [] of Egui::Event, 0.016) do |ui|
      cursor_y = ui.cursor.y
    end
    cursor_y.should be >= Egui::Page::HEADER_H

    ctx2 = Egui::Context.new
    cursor_y2 = 0.0
    raw = Egui::RawInput.new(PAGE_SCREEN, [] of Egui::Event, 0.032)
    ctx2.begin_frame(raw)
    ctx2.page("bare") { |ui| cursor_y2 = ui.cursor.y }
    ctx2.end_frame
    cursor_y2.should be < Egui::Page::HEADER_H
  end
end
