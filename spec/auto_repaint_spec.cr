# AutoRepaint module specs: a widget whose content changes outside the
# input stream must keep the on-demand frame loop running by itself —
# mutations request frames, and the loop stops once changes stop.
require "spec"
require "../src/egui"

AR_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(400.0, 300.0))

def ar_frame(ctx : Egui::Context, canvas : Egui::Canvas) : Nil
  ctx.begin_frame(Egui::RawInput.new(AR_SCREEN, [] of Egui::Event, 0.016))
  ctx.central_panel do |ui|
    ui.canvas(canvas) { |_ia| }
  end
  ctx.end_frame
end

describe Egui::AutoRepaint do
  it "a change before the first show is consumed by the first pump" do
    ctx = Egui::Context.new
    canvas = Egui::Canvas.new("ar1", 4, 4)
    canvas.line(0, 0, 3, 3, Egui::Color32.rgb(0, 0, 0)) # no Context yet: pending
    ctx.needs_repaint?.should be_false
    ar_frame(ctx, canvas) # pump consumes the pending change
    canvas.dirty?.should be_false # texture created + uploaded this frame
    ctx.needs_repaint?.should be_true
  end

  it "a mutation between frames requests a frame on its own" do
    ctx = Egui::Context.new
    canvas = Egui::Canvas.new("ar2", 4, 4)
    ar_frame(ctx, canvas)
    3.times { ar_frame(ctx, canvas) } # settle: no mutations
    ctx.needs_repaint?.should be_false # idle: mutations stopped

    canvas[1, 1] = Egui::Color32.rgb(255, 0, 0) # out-of-frame content change
    ctx.needs_repaint?.should be_true
  end

  it "an unchanged canvas stops requesting frames" do
    ctx = Egui::Context.new
    canvas = Egui::Canvas.new("ar3", 4, 4)
    ar_frame(ctx, canvas)
    5.times { ar_frame(ctx, canvas) } # no mutations at all
    ctx.needs_repaint?.should be_false
  end
end
