# Regression: Memory's slot recycling once deleted an id's LIVE mapping
# through a stale @slot_ids entry (an id that re-registered after a frame
# of absence and landed at a different slot), re-pushed the already-free
# index into @slot_free, and handed one slot to two ids. The ghost
# @slot_of entry survived compact_slots as an index past the shrunken
# SoA arrays, and the next #use_id for that id crashed with IndexError
# (seen live: html_gallery's virtual scroll churning textareas).

require "spec"
require "../src/egui"

SLOT_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def slots_frame(ctx : Egui::Context, &app : Egui::Memory ->)
  ctx.begin_frame(Egui::RawInput.new(SLOT_SCREEN, [] of Egui::Event, 0.016))
  yield ctx.memory
  ctx.end_frame
end

def slots_reg(m : Egui::Memory, id : Egui::Id) : Nil
  m.interact(id,
    Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(10.0, 10.0)),
    Egui::Sense::Click)
end

describe "Memory slot recycling" do
  it "never leaves a ghost slot mapping after free/re-register churn" do
    ctx = Egui::Context.new
    keep = ("k0".."k9").map { |s| Egui::Id.from(s) }
    x = Egui::Id.from("x")
    y = Egui::Id.from("y")
    w = Egui::Id.from("w")
    v = Egui::Id.from("v")

    # x and y take the last two slots after ten keep-alive ids (x is
    # not the last — its re-registration must LIFO-pop y's slot).
    slots_frame(ctx) do |m|
      keep.each { |k| slots_reg(m, k) }
      m.use_id(x)
      slots_reg(m, y)
    end
    # Both absent for a frame: freed, but not enough holes to compact.
    slots_frame(ctx) { |m| keep.each { |k| slots_reg(m, k) } }
    # x returns at y's old slot; the stale entry for x at ITS old index
    # used to delete x's live mapping here and double-push that index.
    slots_frame(ctx) do |m|
      keep.each { |k| slots_reg(m, k) }
      m.use_id(x)
    end
    # w and v recycle the (once duplicated) index; w used to become a
    # ghost mapping invisible to end_frame's pruning.
    slots_frame(ctx) do |m|
      keep.each { |k| slots_reg(m, k) }
      slots_reg(m, w)
      slots_reg(m, v)
    end
    # Heavy churn: only two survivors, compaction shrinks the arrays.
    slots_frame(ctx) do |m|
      slots_reg(m, Egui::Id.from("p0"))
      slots_reg(m, Egui::Id.from("p1"))
    end
    # The ghost id re-registers against the shrunken arrays — this was
    # `@cur_used[i]` with i out of bounds.
    slots_frame(ctx) { |m| m.use_id(w) }
    # And again on the next frame, through the interaction reader too.
    slots_frame(ctx) { |m| m.interaction_state(w) }
  end
end
