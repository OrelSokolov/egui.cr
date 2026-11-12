# Flexbox specs (Ui#flex / Egui::Flex) — the full CSS algorithm over a
# deterministic container: a `position: fixed` box stretched over the
# viewport (all four offsets) has the definite region (0,0,800,600) and
# margin zero, so every slot lands at computable coordinates. Geometry
# is asserted on the FIRST frame — the two-pass measure makes flex
# exact immediately (no Grid-style one-frame settle).

require "spec"
require "../src/egui"

FLEX_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# A flex item of an exact natural size; records its slot (the child
# Ui's max_rect) once per REAL pass — the `measuring?` guard doubles
# as the assertion that the measure pass stays invisible to app code.
class FlexItem
  include Egui::Widget

  def initialize(@size : Egui::Vec2, @slots : Array(Egui::Rect)? = nil)
  end

  def ui(ui : Egui::Ui) : Egui::Response
    rect = ui.allocate_space(@size)
    @slots.try &.push(ui.max_rect) unless ui.measuring?
    Egui::Response.container(ui.ctx, ui.id, rect)
  end
end

def flex_frame(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event,
               &app : Egui::Context ->)
  ctx.begin_frame(Egui::RawInput.new(FLEX_SCREEN, events, 0.016))
  yield ctx
  ctx.end_frame
end

# Element-wise close comparison for arrays of expected slot extents.
def expect_close(actual : Array(Float64), expected : Array(Float64),
                 tol = 0.5) : Nil
  actual.size.should eq expected.size
  actual.zip(expected).each do |(a, e)|
    a.should be_close(e, tol)
  end
end

def slot_lefts(slots : Array(Egui::Rect)) : Array(Float64)
  slots.map(&.left)
end

def slot_tops(slots : Array(Egui::Rect)) : Array(Float64)
  slots.map(&.top)
end

def slot_widths(slots : Array(Egui::Rect)) : Array(Float64)
  slots.map(&.width)
end

def slot_heights(slots : Array(Egui::Rect)) : Array(Float64)
  slots.map(&.height)
end

# Run one frame of `ui.flex(**opts)` over the fixed 800×600 region and
# return the children's slots.
def flex_slots(**opts, &build : Egui::Flex, Array(Egui::Rect) ->)
  ctx = Egui::Context.new
  slots = [] of Egui::Rect
  flex_frame(ctx) do |c|
    c.window("w") do |ui|
      ui.flex(**opts, position: :fixed, top: 0, right: 0, bottom: 0, left: 0,
        margin: Egui::Vec2.zero) { |f| build.call(f, slots) }
    end
  end
  slots
end

def three_items(f : Egui::Flex, slots : Array(Egui::Rect))
  3.times { f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), slots)) }
end

# `level` nested ui.flex containers, `leaf` innermost — the
# exponential-blowup guard spec drives this.
def nest_flex(ui : Egui::Ui, level : Int32, &leaf : Egui::Ui ->) : Nil
  if level == 0
    leaf.call(ui)
    return
  end
  ui.flex do |f|
    f.child { |c2| nest_flex(c2, level - 1, &leaf) }
  end
end

describe "Ui#flex" do
  it "is exact on the first frame (no settle)" do
    slots = flex_slots { |f, s| three_items(f, s) }
    slots.size.should eq 3
    expect_close(slot_lefts(slots), [0.0, 40.0, 80.0])
  end

  describe "justify-content" do
    it "start packs from the main start" do
      slots = flex_slots { |f, s| three_items(f, s) }
      expect_close(slot_lefts(slots), [0.0, 40.0, 80.0], 0.5)
    end

    it "center" do
      slots = flex_slots(justify: :center) { |f, s| three_items(f, s) }
      # free = 800-120 = 680 → first offset 340
      expect_close(slot_lefts(slots), [340.0, 380.0, 420.0], 0.5)
    end

    it "end" do
      slots = flex_slots(justify: :end) { |f, s| three_items(f, s) }
      expect_close(slot_lefts(slots), [680.0, 720.0, 760.0], 0.5)
    end

    it "space-between" do
      slots = flex_slots(justify: :space_between) { |f, s| three_items(f, s) }
      expect_close(slot_lefts(slots), [0.0, 380.0, 760.0], 0.5)
    end

    it "space-around" do
      slots = flex_slots(justify: :space_around) { |f, s| three_items(f, s) }
      # 680/3 per item around: first at 680/6, then +180 apart… spacing
      # = 680/3 between adjacent items, 680/6 at the ends.
      expect_close(slot_lefts(slots),
        [680.0 / 6, 40.0 + 680.0 / 2, 80.0 + 680.0 * 5 / 6])
    end

    it "space-evenly" do
      slots = flex_slots(justify: :space_evenly) { |f, s| three_items(f, s) }
      expect_close(slot_lefts(slots), [170.0, 380.0, 590.0], 0.5)
    end
  end

  it "row-reverse mirrors the main axis" do
    slots = flex_slots(direction: :row_reverse) { |f, s| three_items(f, s) }
    expect_close(slot_lefts(slots), [760.0, 720.0, 680.0], 0.5)
  end

  describe "flex-direction column" do
    it "justify end stacks from the bottom of a definite height" do
      slots = flex_slots(direction: :column, justify: :end) { |f, s| three_items(f, s) }
      expect_close(slot_tops(slots), [540.0, 560.0, 580.0], 0.5)
    end

    it "column-reverse mirrors the main axis" do
      slots = flex_slots(direction: :column_reverse) { |f, s| three_items(f, s) }
      expect_close(slot_tops(slots), [580.0, 560.0, 540.0], 0.5)
    end
  end

  describe "flex-grow / flex-shrink / basis" do
    it "grow divides free space by the factors (explicit basis 0)" do
      slots = flex_slots { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s), grow: 1, basis: 0.0)
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s), grow: 3, basis: 0.0)
      }
      expect_close(slot_widths(slots), [200.0, 600.0], 0.5)
    end

    it "an auto basis never grows past the natural size (CSS max-content cap)" do
      slots = flex_slots { |f, s|
        2.times { f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s), grow: 1) }
      }
      expect_close(slot_widths(slots), [40.0, 40.0], 0.5)
    end

    it "shrink takes overflow proportionally to shrink × size" do
      slots = flex_slots { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(20.0, 20.0), s), basis: 500.0)
        f.add(FlexItem.new(Egui::Vec2.new(20.0, 20.0), s), basis: 500.0)
      }
      expect_close(slot_widths(slots), [400.0, 400.0], 0.5)
    end

    it "percentage basis resolves against the definite main axis" do
      slots = flex_slots { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(20.0, 20.0), s), basis: "50%")
        f.add(FlexItem.new(Egui::Vec2.new(20.0, 20.0), s), basis: "25%")
      }
      expect_close(slot_widths(slots), [400.0, 200.0], 0.5)
    end
  end

  it "order reorders the visual sequence" do
    slots = flex_slots { |f, s|
      f.add(FlexItem.new(Egui::Vec2.new(30.0, 20.0), s), order: 2)
      f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s), order: 0)
      f.add(FlexItem.new(Egui::Vec2.new(50.0, 20.0), s), order: 1)
    }
    # slots record in RUN order: B (order 0) first, then C (1), A (2).
    expect_close(slot_widths(slots), [40.0, 50.0, 30.0], 0.5)
    expect_close(slot_lefts(slots), [0.0, 40.0, 90.0], 0.5)
  end

  it "gap spaces the main axis" do
    slots = flex_slots(gap: Egui::Vec2.new(10.0, 10.0)) { |f, s|
      three_items(f, s)
    }
    expect_close(slot_lefts(slots), [0.0, 50.0, 100.0], 0.5)
  end

  describe "flex-wrap" do
    it "wraps onto a new line when the main axis overflows" do
      slots = flex_slots(wrap: :wrap, align_content: :start) { |f, s|
        3.times { f.add(FlexItem.new(Egui::Vec2.new(300.0, 20.0), s)) }
      }
      slots[0].top.should be_close 0.0, 0.5
      slots[1].top.should be_close 0.0, 0.5
      slots[2].top.should be_close 20.0, 0.5 # line 2
    end

    it "wrap-reverse stacks the lines bottom-up" do
      slots = flex_slots(wrap: :wrap_reverse, align_content: :start) { |f, s|
        3.times { f.add(FlexItem.new(Egui::Vec2.new(300.0, 20.0), s)) }
      }
      # line 1 mirrors to the bottom of the definite cross axis
      slots[0].top.should be_close 580.0, 0.5
      slots[2].top.should be_close 560.0, 0.5
    end

    it "align-content space-between pushes the lines apart" do
      slots = flex_slots(wrap: :wrap, align_content: :space_between) { |f, s|
        3.times { f.add(FlexItem.new(Egui::Vec2.new(300.0, 20.0), s)) }
      }
      slots[0].top.should be_close 0.0, 0.5
      slots[2].top.should be_close 580.0, 0.5
    end
  end

  describe "align-items" do
    # The definite-height harness container stretches a nowrap line
    # onto the full cross size (CSS §9.4, `align-content: stretch`);
    # these tests pin align-ITEMS semantics against the line's natural
    # extent, so they opt out with `align_content: :start`.
    it "stretch gives the child the line's cross extent" do
      slots = flex_slots(align_content: :start) { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s))
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 50.0), s))
      }
      slots[0].height.should be_close 50.0, 0.5
    end

    it "a nowrap definite cross stretches the line (CSS §9.4)" do
      slots = flex_slots { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s))
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 50.0), s))
      }
      # the 600-tall container: every child's slot stretches to it
      slots[0].height.should be_close 600.0, 0.5
      slots[1].height.should be_close 600.0, 0.5
    end

    it "end bottom-aligns within the line" do
      slots = flex_slots(align: :end, align_content: :start) { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s))
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 50.0), s))
      }
      slots[0].top.should be_close 30.0, 0.5
      slots[1].top.should be_close 0.0, 0.5
    end

    it "center centers within the line" do
      slots = flex_slots(align: :center, align_content: :start) { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s))
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 50.0), s))
      }
      slots[0].top.should be_close 15.0, 0.5
    end

    it "align-self overrides the container's align" do
      slots = flex_slots(align: :end, align_content: :start) { |f, s|
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), s), align_self: :start)
        f.add(FlexItem.new(Egui::Vec2.new(40.0, 50.0), s))
      }
      slots[0].top.should be_close 0.0, 0.5
    end
  end

  describe "the measure pass" do
    it "runs child blocks twice but real-pass work once (ui.measuring?)" do
      ctx = Egui::Context.new
      runs = {measured: 0, real: 0, unguarded: 0}
      flex_frame(ctx) do |c|
        c.window("w") do |ui|
          ui.flex(position: :fixed, top: 0, right: 0, bottom: 0, left: 0,
            margin: Egui::Vec2.zero) do |f|
            f.child do |c2|
              if c2.measuring?
                runs = {measured: runs[:measured] + 1, real: runs[:real],
                        unguarded: runs[:unguarded]}
              else
                runs = {measured: runs[:measured], real: runs[:real] + 1,
                        unguarded: runs[:unguarded]}
              end
              runs = {measured: runs[:measured], real: runs[:real],
                unguarded: runs[:unguarded] + 1}
              c2.label("x")
            end
          end
        end
      end
      runs[:measured].should eq 1
      runs[:real].should eq 1
      runs[:unguarded].should eq 2 # the documented two-pass contract
    end

    it "nested flexes run their blocks linearly, not 2^depth" do
      # The exponential-blowup regression: a flex rendering inside an
      # ancestor's measure pass must run its subtree ONCE (measure
      # mode), and the real pass reuses the per-frame measure memo —
      # depth-6 nesting must not run the leaf 64 times.
      ctx = Egui::Context.new
      runs = 0
      leaf = ->(c : Egui::Ui) do
        runs += 1
        c.label("x")
      end
      flex_frame(ctx) do |c|
        c.window("w") do |ui|
          nest_flex(ui, 6, &leaf)
        end
      end
      runs.should be < 64        # the old 2^depth blow-up
      runs.should be <= 12       # linear in depth (~depth + 1)
    end

    it "a response-gated callback fires exactly once per click" do
      ctx = Egui::Context.new
      clicks = 0
      btn_rect = Egui::Rect.zero
      app = ->(c : Egui::Context) {
        c.window("w") do |ui|
          ui.flex(margin: Egui::Vec2.zero) do |f|
            f.child do |c2|
              resp = c2.button("Go")
              btn_rect = resp.rect
              clicks += 1 if resp.clicked?
            end
          end
        end
      }
      flex_frame(ctx) { |c| app.call(c) } # frame 1: register the button
      center = btn_rect.center
      flex_frame(ctx) { |c| app.call(c) } # frame 2
      # click = press frame, then release frame
      flex_frame(ctx, [Egui::Event.pointer_pressed(center)]) { |c| app.call(c) }
      flex_frame(ctx, [Egui::Event.pointer_released(center)]) { |c| app.call(c) }
      clicks.should eq 1
    end

    it "leaves no paint from the measure pass" do
      ctx = Egui::Context.new
      flex_frame(ctx) do |c|
        c.window("w") do |ui|
          ui.flex(margin: Egui::Vec2.zero) do |f|
            f.child { |c2| c2.label("visible") }
          end
        end
      end
      texts = ctx.painter.commands.count do |cmd|
        cmd.is_a?(Egui::TextCmd) && cmd.text.includes?("visible")
      end
      texts.should eq 1
    end
  end

  describe "Ui#box width/height" do
    it "an explicit height makes a column container's main axis definite" do
      # A column flex inside a plain (in-flow) box with height: 200 —
      # the flow height is content-driven otherwise. The slots assert
      # against the flex's returned content rect (the flow origin
      # depends on the window chrome).
      ctx = Egui::Context.new
      slots = [] of Egui::Rect
      outer = Egui::Rect.zero
      flex_frame(ctx) do |c|
        c.window("w") do |ui|
          outer = ui.flex(direction: :column, height: 200,
            margin: Egui::Vec2.zero, justify: :end) do |f|
            2.times { f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), slots)) }
          end
        end
      end
      # content hugs the bottom of the 200-tall region: two 20-tall
      # children packed at 160/180 from the top.
      (slots[0].top - outer.top).should be_close 160.0, 0.5
      (slots[1].top - outer.top).should be_close 180.0, 0.5
    end
  end

  describe "ECSS cascade" do
    it "justify-content comes from the class rule" do
      ctx = Egui::Context.new
      ctx.stylesheet.rule("toolbar", Egui::StyleVars{
        "justify-content" => "space-between",
      })
      slots = [] of Egui::Rect
      flex_frame(ctx) do |c|
        c.window("w") do |ui|
          ui.flex(position: :fixed, top: 0, right: 0, bottom: 0, left: 0,
            margin: Egui::Vec2.zero, style_class: "toolbar") do |f|
            2.times { f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), slots)) }
          end
        end
      end
      slots[0].left.should be_close 0.0, 0.5
      slots[1].left.should be_close 760.0, 0.5
    end

    it "an explicit argument beats the cascade" do
      ctx = Egui::Context.new
      ctx.stylesheet.rule("toolbar", Egui::StyleVars{
        "justify-content" => "space-between",
      })
      slots = [] of Egui::Rect
      flex_frame(ctx) do |c|
        c.window("w") do |ui|
          ui.flex(position: :fixed, top: 0, right: 0, bottom: 0, left: 0,
            margin: Egui::Vec2.zero, style_class: "toolbar",
            justify: :center) do |f|
            2.times { f.add(FlexItem.new(Egui::Vec2.new(40.0, 20.0), slots)) }
          end
        end
      end
      slots[0].left.should be_close 360.0, 0.5
    end
  end
end
