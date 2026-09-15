require "spec"
require "../src/egui"

TREE_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def tree_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event, time : Float64 = 0.016)
  raw = Egui::RawInput.new(TREE_SCREEN, events, time)
  ctx.begin_frame(raw)
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"),
    Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(300.0, 300.0)))
  ui.tree_view("t") do |tree|
    tree.node("src", default_open: true) do |sub|
      sub.leaf("egui.cr", false) { }
      sub.node("widgets", default_open: true) do |leaf|
        leaf.leaf("button.cr", false) { }
      end
    end
    tree.leaf("README.md", false) { }
  end
  ctx.end_frame
end

def texts(ctx : Egui::Context) : Array(String)
  ctx.painter.commands.select(Egui::TextCmd).map(&.text)
end

describe Egui::TreeView do
  it "collapses an open node on click" do
    ctx = Egui::Context.new

    # frame 1: layout; src and widgets are default-open
    tree_frame(ctx, time: 0.016)
    texts(ctx).should contain("egui.cr")

    # find the "src" node row: the first interact rect registered
    src_center = ctx.memory.widget_rects.values.first.center

    # press + release on it
    tree_frame(ctx, events: [Egui::Event.pointer_moved(src_center),
      Egui::Event.pointer_pressed(src_center)], time: 0.032)
    tree_frame(ctx, events: [Egui::Event.pointer_released(src_center)], time: 0.048)

    tree_frame(ctx, time: 0.064)
    texts(ctx).should contain("src")
    texts(ctx).should_not contain("egui.cr")
  end

  it "expands a closed node on click" do
    ctx = Egui::Context.new

    tree_frame(ctx, time: 0.016)
    texts(ctx).should contain("README.md") # sanity: layout exists

    # collapse src first (default_open: true)
    src_center = ctx.memory.widget_rects.values.first.center
    tree_frame(ctx, events: [Egui::Event.pointer_moved(src_center),
      Egui::Event.pointer_pressed(src_center)], time: 0.032)
    tree_frame(ctx, events: [Egui::Event.pointer_released(src_center)], time: 0.048)
    tree_frame(ctx, time: 0.080)
    texts(ctx).should_not contain("egui.cr")

    # expand it back
    tree_frame(ctx, events: [Egui::Event.pointer_moved(src_center),
      Egui::Event.pointer_pressed(src_center)], time: 0.096)
    tree_frame(ctx, events: [Egui::Event.pointer_released(src_center)], time: 0.112)
    tree_frame(ctx, time: 0.128)
    texts(ctx).should contain("egui.cr")
  end
end
