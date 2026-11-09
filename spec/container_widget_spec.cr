# The element contract for containers (plans/NativeHTML.md §4.1):
# the show(ui) containers (ScrollArea, Grid, ComboBox, TreeView,
# Table) are Widgets — content attaches through the `.content`
# builder and they render through `ui.add` / `Widget#ui`. The legacy
# `show(ui)` sugar keeps its documented return and — crucially —
# stays UNCAPPED: callers' blocks keep plain-local semantics.

require "spec"
require "../src/egui"

CONTAINER_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

def container_frame(ctx : Egui::Context, &app : Egui::Context ->)
  raw = Egui::RawInput.new(CONTAINER_SCREEN, [] of Egui::Event, 0.016)
  ctx.begin_frame(raw)
  yield ctx
  ctx.end_frame
end

describe "container widget protocol" do
  it "ScrollArea renders through ui.add with .content" do
    ctx = Egui::Context.new
    resp = nil
    container_frame(ctx) do |c|
      c.central_panel do |ui|
        scroll = Egui::ScrollArea.new.content do |inner|
          inner.label("scrolled")
        end
        resp = ui.add(scroll)
      end
    end
    r = resp.not_nil!
    r.rect.height.should be > 0.0
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).should contain("scrolled")
  end

  it "Grid renders through ui.add with .content" do
    ctx = Egui::Context.new
    resp = nil
    container_frame(ctx) do |c|
      c.central_panel do |ui|
        grid = Egui::Grid.new("g").content do |g|
          g.label("A"); g.end_row
          g.label("B"); g.end_row
        end
        resp = ui.add(grid)
      end
    end
    resp.not_nil!.rect.width.should be > 0.0
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("A")
    texts.should contain("B")
  end

  it "ComboBox returns the button Response through ui.add" do
    ctx = Egui::Context.new
    resp = nil
    container_frame(ctx) do |c|
      c.central_panel do |ui|
        combo = Egui::ComboBox.new("pick", "Two", ["One", "Two"])
          .on_select { |_| }
        resp = ui.add(combo)
      end
    end
    resp.not_nil!.id.should be_a(Egui::Id)
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).join.should contain("Two")
  end

  it "Table renders through ui.add with .content" do
    ctx = Egui::Context.new
    resp = nil
    container_frame(ctx) do |c|
      c.central_panel do |ui|
        table = Egui::Table.new("t", ["Name", "Size"]).content do |rows|
          rows.label("a.txt"); rows.label("12 KB"); rows.end_row
        end
        resp = ui.add(table)
      end
    end
    resp.not_nil!.rect.width.should be > 0.0
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Name")
    texts.should contain("a.txt")
  end

  it "TreeView renders through ui.add with .content" do
    ctx = Egui::Context.new
    resp = nil
    container_frame(ctx) do |c|
      c.central_panel do |ui|
        tree = Egui::TreeView.new("files").content do |t|
          t.leaf("README.md") { }
        end
        resp = ui.add(tree)
      end
    end
    resp.not_nil!.rect.width.should eq(0.0) # no aggregate rect — documented
    ctx.painter.commands.select(Egui::TextCmd)
      .map(&.text).join.should contain("README.md")
  end

  it "show sugar keeps plain-local block semantics (uncaptured)" do
    ctx = Egui::Context.new
    picked = nil
    container_frame(ctx) do |c|
      c.central_panel do |ui|
        # The `||` nil-filtering on a local assigned INSIDE the show
        # block compiles only while show stays uncaptured.
        last = nil
        ui.scroll_area do |inner|
          inner.label("one")
          last = "seen"
        end
        picked = last || "fallback"
      end
    end
    picked.should eq("seen")
  end
end
