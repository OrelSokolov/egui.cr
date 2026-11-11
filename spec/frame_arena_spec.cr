# FrameArena (plans/FPS_OPTIMIZATION.md §3, stage 0): bump allocation,
# alignment, geometric growth, reset reuse, typed slices.
require "spec"
require "../src/egui"

describe "frame arena" do
  it "carves aligned byte slices at increasing offsets" do
    arena = Egui::FrameArena.new(64)
    a = arena.bytes(1)
    a.size.should eq 1
    arena.bytes_used.should eq 1 # handed-out bytes, next carving aligns up

    b = arena.bytes(9)
    b.size.should eq 9
    arena.bytes_used.should eq 17 # 1 → aligned start 8, plus 9

    # distinct carvings do not overlap
    a.to_unsafe.as(Pointer(UInt8)).address.should_not(
      eq b.to_unsafe.as(Pointer(UInt8)).address)
  end

  it "reset returns to offset 0 and reuses the same memory" do
    arena = Egui::FrameArena.new(64)
    first = arena.bytes(16)
    arena.reset
    arena.bytes_used.should eq 0
    second = arena.bytes(16)
    second.to_unsafe.should eq first.to_unsafe
    arena.capacity.should eq 64 # no growth on reset reuse
  end

  it "grows geometrically and keeps earlier carvings addressable" do
    arena = Egui::FrameArena.new(16)
    small = arena.bytes(8)
    small[0] = 0xAB_u8
    big = arena.bytes(64) # forces growth past 16
    big.size.should eq 64
    arena.capacity.should be >= 72
    small[0].should eq 0xAB_u8 # old carving still valid
  end

  it "hands out typed slices over the slab" do
    arena = Egui::FrameArena.new(64)
    xs = arena.slice(Float64, 4)
    xs.size.should eq 4
    xs[0] = 1.5
    xs[3] = -2.25
    xs[0].should eq 1.5
    xs[3].should eq -2.25
    arena.bytes_used.should eq 32
    # a second carving starts after the first, no overlap
    ys = arena.slice(Float64, 1)
    ys.to_unsafe.should eq xs.to_unsafe + 4
  end

  it "rejects negative sizes" do
    arena = Egui::FrameArena.new
    expect_raises(ArgumentError) { arena.bytes(-1) }
  end

  it "is owned by the context and reset by end_frame" do
    ctx = Egui::Context.new
    arena = ctx.frame_arena
    arena.bytes(32)
    ctx.begin_frame(Egui::RawInput.new)
    ctx.end_frame
    arena.bytes_used.should eq 0
  end
end
