# Composited scroll (plans/COMPOSITED_SCROLL.md): the ScrollArea
# `composited: true` bracket emission, the overscan band culling, the
# mesh3d fallback, the gesture gate over the kinetic scroller, and the
# legacy no-driver gate. Headless: a stub Driver::Base with
# `composited_scroll? true` stands in for the detached render thread —
# the wheel interception itself lives in backend/sokol_shim.c and is
# covered by the twinshot A/B (stage-1 identity) instead.

require "spec"
require "../src/egui"

CS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(300.0, 300.0))
CS_ID = Egui::Id.from("cs-spec")

# A detached-render-thread stand-in: only the capability flag matters
# headlessly (run/wake are never called — no window is opened).
class CS::FakeDriver < Egui::Driver::Base
  def run : Nil
  end

  def stop : Nil
  end

  def wake : Nil
  end

  def gui_context? : Bool
    false
  end

  def run_on_main(&block : ->) : Nil
  end

  def composited_scroll? : Bool
    true
  end
end

private def cs_with_driver
  old = Egui::Driver::Base.current
  Egui::Driver::Base.current = CS::FakeDriver.new
  begin
    yield
  ensure
    Egui::Driver::Base.current = old
  end
end

# Frame clock: cs_frame auto-increments (a constant time would zero
# every dt after the first frame and freeze the kinetic scroller).
CS_TIME = [0.0]

# One frame of a composited scroll area with `rows` labeled rows in a
# 150-px viewport. Returns the frame's commands.
private def cs_frame(ctx : Egui::Context, rows : Int32 = 60,
                     mesh3d : Bool = false,
                     gesture : Bool = false) : Array(Egui::PaintCmd)
  CS_TIME[0] += 0.016
  ctx.clear_composited_gestures
  ctx.add_composited_gesture(CS_ID) if gesture
  # (a local for the clock: `[] of Egui::Event, CONST[0]` in one
  # argument list trips the parser — see scroll_drag_spec's locals)
  time = CS_TIME[0]
  ctx.begin_frame(Egui::RawInput.new(CS_SCREEN, [] of Egui::Event, time))
  ui = Egui::Ui.new(ctx, Egui::Id.from("spec"), CS_SCREEN)
  Egui::ScrollArea.new(max_height: 150.0, id: CS_ID, composited: true)
    .content { |area|
      rows.times { |i| area.label("cs row #{i}") }
      # A 3D mesh inside the band forces the bracket's fallback (an
      # mvp-owning primitive cannot ride a present-time translate).
      if mesh3d
        vp = Egui::Rect.from_min_size(Egui::Pos2.new(10.0, 10.0),
          Egui::Vec2.new(50.0, 50.0))
        area.painter.mesh3d(vp, Egui::Mat4.identity,
          Bytes.new(3 * 16), :triangles, blend: true)
      end
    }.ui(ui)
  ctx.end_frame
end

private def cs_brackets(cmds) : Array(Egui::ScrollBracketCmd)
  cmds.select(Egui::ScrollBracketCmd)
end

private def cs_text_with(cmds, text : String) : Bool
  cmds.any? { |c| c.is_a?(Egui::TextCmd) && c.text.includes?(text) }
end

describe "composited scroll" do
  it "emits a bracket pair with the window and rides the painter's id list" do
    cs_with_driver do
      ctx = Egui::Context.new
      cmds = cs_frame(ctx)
      brs = cs_brackets(cmds)
      brs.size.should eq(2)
      first = brs.first
      first.end?.should be_false
      first.id.should eq(CS_ID.value)
      # window = viewport ∩ ambient clip: a 150-px viewport at the top
      # of a 300-px screen (the spec Ui adds no clip of its own).
      first.window.min.y.should be >= 0.0
      first.window.height.should be <= 150.0
      brs.last.end?.should be_true
      ctx.painter.scroll_layer_ids.should contain(CS_ID.value)
    end
  end

  it "no driver (legacy/headless): the flag is inert, no bracket" do
    ctx = Egui::Context.new
    cmds = cs_frame(ctx)
    cs_brackets(cmds).should be_empty
    ctx.painter.scroll_layer_ids.should be_empty
  end

  it "overscan band keeps below-the-fold rows painted, beyond-band culled" do
    cs_with_driver do
      ctx = Egui::Context.new
      3.times { cs_frame(ctx) }
      cmds = cs_frame(ctx)
      # Band = 2 viewports past the 150-px window ≈ 450 px of content
      # at a ~25-px row pitch (the classic path above paints rows 0–5
      # only). The band keeps everything to ~row 18 in the packet —
      # the compositor replays it while A catches up; beyond the band
      # stays culled.
      cs_text_with(cmds, "cs row 0").should be_true
      cs_text_with(cmds, "cs row 5").should be_true   # below the fold, in band
      cs_text_with(cmds, "cs row 15").should be_true  # deep in the band
      cs_text_with(cmds, "cs row 40").should be_false # beyond the band
    end
  end

  it "a mesh3d inside the band demotes the bracket (fallback, re-clipped)" do
    cs_with_driver do
      ctx = Egui::Context.new
      cmds = cs_frame(ctx, mesh3d: true)
      cs_brackets(cmds).should be_empty
      # The content still draws (classic semantics: clipped to the
      # viewport, not the band).
      cs_text_with(cmds, "cs row 0").should be_true
      cs_text_with(cmds, "cs row 40").should be_false
    end
  end
  it "an active gesture stands the kinetic scroller down (no glide)" do
    cs_with_driver do
      ctx = Egui::Context.new
      2.times { cs_frame(ctx) }
      # A stale Crystal-side velocity (as if a glide were mid-flight)
      # plus a live gesture: the render thread owns the offset — the
      # next frame must not move it (takeover), while WITHOUT the
      # gesture the same velocity glides on.
      ctx.memory.data.set_vec2(CS_ID, Egui::Vec2.new(0.0, 100.0))
      ctx.memory.data.set_f64(CS_ID.child(3), 600.0)

      cs_frame(ctx, gesture: true)
      offset = ctx.memory.data.get_vec2(CS_ID, Egui::Vec2.zero).y
      offset.should eq(100.0)
      ctx.memory.data.get_f64(CS_ID.child(3), 0.0).should eq(0.0)

      # Same stale velocity without a gesture: the glide moves it.
      ctx.memory.data.set_vec2(CS_ID, Egui::Vec2.new(0.0, 100.0))
      ctx.memory.data.set_f64(CS_ID.child(3), 600.0)
      cs_frame(ctx, gesture: false)
      ctx.memory.data.get_vec2(CS_ID, Egui::Vec2.zero).y.should be > 100.0
    end
  end
end
