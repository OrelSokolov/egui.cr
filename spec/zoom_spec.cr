require "spec"
require "../src/egui"

# Event.zoom → InputState#zoom_delta / #zoom_pos: the pinch-zoom
# half-frame contract the sokol shim feeds (backend/sokol_shim.c,
# SH_EVENT_PINCH → Event.zoom, see backend/sokol.cr#translate_event).

ZOOM_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

def zoom_input_state(events : Array(Egui::Event)) : Egui::InputState
  Egui::InputState.build(
    Egui::RawInput.new(ZOOM_SCREEN, events, 0.016), nil, nil)
end

describe "pinch zoom input" do
  it "defaults to no zoom" do
    state = zoom_input_state([] of Egui::Event)
    state.zoom_delta.should eq(1.0)
    state.zoom_pos.should be_nil
  end

  it "multiplies zoom factors within one frame" do
    state = zoom_input_state([
      Egui::Event.zoom(1.1, Egui::Pos2.new(10.0, 20.0)),
      Egui::Event.zoom(1.2, Egui::Pos2.new(30.0, 40.0)),
    ] of Egui::Event)
    state.zoom_delta.should be_close(1.32, 1e-9)
  end

  it "keeps the last focal point" do
    state = zoom_input_state([
      Egui::Event.zoom(0.5, Egui::Pos2.new(10.0, 20.0)),
      Egui::Event.zoom(0.5, Egui::Pos2.new(30.0, 40.0)),
    ] of Egui::Event)
    state.zoom_pos.should eq(Egui::Pos2.new(30.0, 40.0))
  end

  it "resets zoom each frame (not accumulated across frames)" do
    prev = zoom_input_state([Egui::Event.zoom(2.0)] of Egui::Event)
    prev.zoom_delta.should eq(2.0)
    next_state = Egui::InputState.build(
      Egui::RawInput.new(ZOOM_SCREEN, [] of Egui::Event, 0.032), prev, 0.016)
    next_state.zoom_delta.should eq(1.0)
  end

  it "zooms out for factors below one" do
    state = zoom_input_state([Egui::Event.zoom(0.75)] of Egui::Event)
    state.zoom_delta.should eq(0.75)
  end
end
