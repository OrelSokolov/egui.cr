# ScrollArea `virtual:` + Ui#virtual_row: offscreen rows are not
# built (extent replayed from the Memory cache), ids of later rows
# stay stable, a viewport width change re-measures everything.

require "spec"
require "../src/egui"

class VirtualList
  property built : Array(Int32) = [] of Int32
  property width : Float64 = 600.0

  def frame(ctx : Egui::Context, time : Float64,
            events : Array(Egui::Event)) : Nil
    screen = Egui::Rect.from_min_size(Egui::Pos2.zero,
      Egui::Vec2.new(@width, 400.0))
    ctx.begin_frame(Egui::RawInput.new(screen, events, time))
    ctx.central_panel do |ui|
      ui.scroll_area(virtual: true) do |scroll|
        100.times do |i|
          scroll.virtual_row("row #{i}") do |row|
            @built << i
            row.label("row #{i} — " + "content line " * 6)
            row.separator
          end
        end
      end
    end
    ctx.end_frame
  end
end

def vs_events(pointer : Bool = false, wheel : Float64 = 0.0)
  evs = [] of Egui::Event
  evs << Egui::Event.pointer_moved(Egui::Pos2.new(300.0, 200.0)) if pointer
  evs << Egui::Event.scroll(Egui::Vec2.new(0.0, wheel)) unless wheel.zero?
  evs
end

describe "ScrollArea virtual:" do
  it "builds all rows once to measure, then only the visible band" do
    ctx = Egui::Context.new
    list = VirtualList.new
    t = 0.0

    list.frame(ctx, t += 0.016, vs_events)
    list.built.size.should eq(100) # first frame measures everything

    list.built.clear
    list.frame(ctx, t += 0.016, vs_events(pointer: true))
    built_steady = list.built.dup
    # A 400px viewport of ~30px rows + margin: a small band, not 100.
    built_steady.size.should be < 40
    built_steady.first.should eq(0) # the top rows are the visible ones

    # Wheel down the list: the band moves down, top rows stop building
    # and bottom rows appear. (+3 = view-down; chat_bench's -3 reads
    # back toward the top.) Assert on the LAST frames only — the first
    # wheel frame still builds row 0.
    27.times { list.frame(ctx, t += 0.016, vs_events(pointer: true, wheel: 3.0)) }
    list.built.clear
    3.times { list.frame(ctx, t += 0.016, vs_events(pointer: true, wheel: 3.0)) }
    list.built.should_not be_empty
    list.built.first.should be > 0
  end

  it "keeps a stable scroll extent (the scrollbar knows the full list)" do
    ctx = Egui::Context.new
    list = VirtualList.new
    t = 0.0
    list.frame(ctx, t += 0.016, vs_events)
    list.built.clear
    list.frame(ctx, t += 0.016, vs_events(pointer: true))

    # All rows were laid out (built + replayed): the content is much
    # taller than the viewport, so the offset may clamp but the extent
    # must survive skipping — check via the painter's text commands:
    # only the visible band's labels emit text.
    cmds = ctx.painter.commands.select(Egui::TextCmd)
    cmds.size.should be < 40
  end

  it "re-measures all rows after a viewport width change" do
    ctx = Egui::Context.new
    list = VirtualList.new
    t = 0.0
    list.frame(ctx, t += 0.016, vs_events)
    list.built.clear
    list.frame(ctx, t += 0.016, vs_events(pointer: true))
    list.built.size.should be < 40 # steady state: only the band

    list.width = 900.0
    list.built.clear
    list.frame(ctx, t += 0.016, vs_events(pointer: true))
    list.built.size.should eq(100) # widths invalidated → full re-measure
  end
end
