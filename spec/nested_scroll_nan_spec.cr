# Regression repro for the NaN crash (Egui::NaNError) in nested
# scroll areas: stress_scroll case «вложенный скролл (area)» —
# 1000 `scroll_area(max_height: 60)` rows inside an outer scroll_area.
# The live app crashed on case switch and on tab-hide mid-inertia; this
# drives the same sequences headlessly. Any NaN geometry now aborts
# with Egui::NaNError naming its birthplace — the spec just has to run
# the frames without one.
require "spec"
require "../src/egui"

NS_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(850.0, 687.0))

class NestedScrollApp
  property mode : Symbol = :labels

  def frame(ctx : Egui::Context, time : Float64,
            events : Array(Egui::Event) = [] of Egui::Event) : Nil
    ctx.begin_frame(Egui::RawInput.new(NS_SCREEN, events, time))
    ctx.central_panel do |ui|
      case @mode
      when :labels
        ui.scroll_area do |scroll|
          1000.times { |i| scroll.label("Строка ##{i}") }
        end
      when :nestedbox
        ui.heading("1000 × nested box")
        ui.separator
        ui.scroll_area do |scroll|
          1000.times do |i|
            scroll.box(fill: Egui::Color32.rgba(40, 44, 52, 255)) do |outer|
              outer.box(stroke: Egui::Color32.rgba(80, 86, 98, 255)) do |inner|
                inner.label("Вложенный ##{i}", userselect: false)
              end
            end
          end
        end
      when :nested
        ui.scroll_area do |scroll|
          1000.times do |i|
            scroll.scroll_area(max_height: 60.0) do |inner|
              5.times { |r| inner.label("Область ##{i}, строка #{r + 1}") }
            end
          end
        end
      end
    end
    ctx.end_frame
  end
end

def ns_events(wheel : Float64 = 0.0, pointer : Bool = true)
  evs = [] of Egui::Event
  evs << Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 300.0)) if pointer
  evs << Egui::Event.scroll(Egui::Vec2.new(0.0, wheel)) unless wheel.zero?
  evs
end

describe "nested scroll NaN repro" do
  it "survives case switch, wheel bursts, inertia and hide/show" do
    ctx = Egui::Context.new
    app = NestedScrollApp.new
    t = 0.0

    # Plain labels first (the app's default case), give the wheel a ride.
    app.frame(ctx, t += 0.016, ns_events)
    5.times { app.frame(ctx, t += 0.016, ns_events(wheel: 3.0)) }
    10.times { app.frame(ctx, t += 0.016, ns_events) } # inertia glide

    # The nested-box case: crashes the live app on its first frames
    # (Egui::NaNError from Rect.from_min_size — phantom NaN).
    app.mode = :nestedbox
    30.times { app.frame(ctx, t += 0.016, ns_events) }

    # Switch to the nested-scroll case mid-glide (the live crash).
    app.mode = :nested
    app.frame(ctx, t += 0.016, ns_events)

    # Wheel bursts down/up with glide gaps, like the repro driver.
    4.times do
      20.times { app.frame(ctx, t += 0.016, ns_events(wheel: 3.0)) }
      10.times { app.frame(ctx, t += 0.016, ns_events) }
      10.times { app.frame(ctx, t += 0.016, ns_events(wheel: -3.0)) }
      10.times { app.frame(ctx, t += 0.016, ns_events) }
    end

    # Hide the whole thing for a few frames (tab switch), then back.
    app.mode = :labels
    app.frame(ctx, t += 0.016, ns_events(wheel: 3.0))
    5.times { app.frame(ctx, t += 0.016, ns_events) }
    app.mode = :nested
    app.frame(ctx, t += 0.016, ns_events)
    10.times { app.frame(ctx, t += 0.016, ns_events) }
  end
end
