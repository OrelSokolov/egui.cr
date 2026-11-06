# lottie_native — the rlottie C shim backend (backend/rlottie.cr),
# the REFERENCE half of the live A/B pair: the same chat-emoji demo
# as examples/lottie_crystal.cr, pixel source = librlottie.a through
# the C shim. Run the two binaries side by side to eyeball parity.
#
# Build (the rlottie shim is dev-only, behind the LOTTIE flag):
#   LOTTIE=1 rake build:dev[lottie_native]

require "../src/egui/driver_selector"
require "../src/egui/driver/rlottie"

class LottieNativeApp < Egui::App
  EMOJI = [{"1f600", "grinning"}, {"1f602", "tears of joy"},
           {"1f622", "crying"}, {"1f60d", "heart eyes"},
           {"1f44d", "thumbs up"}, {"1f525", "fire"},
           {"1f389", "party"}, {"2764", "heart"}]

  # Renderer wrapper measuring live render ms/frame — the widget
  # rasterizes internally, so the seam is the only hook.
  class Timed < Egui::Lottie::Renderer
    def initialize(@inner : Egui::Lottie::Renderer)
    end

    def width : Int32
      @inner.width
    end

    def height : Int32
      @inner.height
    end

    def frame_count : Int32
      @inner.frame_count
    end

    def fps : Float64
      @inner.fps
    end

    def render(frame : Int32, buf : Bytes,
               w : Int32, h : Int32) : Bool
      t0 = Time.instant
      ok = @inner.render(frame, buf, w, h)
      dt = (Time.instant - t0).total_seconds * 1000.0
      @@sum += dt
      @@calls += 1
      ok
    end

    def self.ms_per_frame : Float64
      @@calls.zero? ? 0.0 : @@sum / @@calls
    end

    @@sum = 0.0
    @@calls = 0
  end

  @players : Array(Egui::Lottie::Player)
  @speed : Float64 = 1.0
  @renders_mark = 0

  def initialize
    super()
    @players = EMOJI.map do |codepoint, _name|
      anim = Egui::Driver::Rlottie::Animation
        .from_json(File.read("assets/lottie/emoji/#{codepoint}.json"))
      raise "rlottie rejected #{codepoint}" unless anim
      player = Egui::Lottie::Player.new(Timed.new(anim))
      player.play
      player
    end
  end

  @@ui_frames = 0
  @@fps_window_start = Time.instant
  @@ui_fps = 0.0
  @@renders_per_sec = 0.0

  def update(ctx : Egui::Context) : Nil
    # Playing animations need continuous repaints — on-demand mode
    # would freeze the clocks between interactions.
    ctx.request_repaint if @players.any?(&.playing?)

    now = Time.instant
    @@ui_frames += 1
    if (now - @@fps_window_start).total_seconds >= 1.0
      dt = (now - @@fps_window_start).total_seconds
      @@ui_fps = @@ui_frames / dt
      renders = Egui::Bench.counters.fetch("lottie.render", 0)
      @@renders_per_sec = (renders - @renders_mark) / dt
      @renders_mark = renders
      @@ui_frames = 0
      @@fps_window_start = now
    end

    ctx.window("Lottie — chat emoji", Egui::Pos2.new(40.0, 40.0), width: 640.0) do |ui|
      ui.horizontal do |h|
        @players.each do |player|
          h.lottie(player, Egui::Vec2.new(64.0, 64.0))
        end
      end

      ui.separator
      playing = @players.any?(&.playing?)
      if ui.button(playing ? "Pause all" : "Play all").clicked?
        @players.each(&.toggle)
      end
      ui.slider(@speed, 0.25..2.0, "speed") do |v|
        @speed = v
        @players.each { |p| p.speed = v }
      end
      ui.label("rlottie (C shim) — #{"%.1f" % @players.first.renderer.fps} fps, " \
               "#{"%.2f" % Timed.ms_per_frame} ms/frame avg, " \
               "#{"%.0f" % @@ui_fps} UI fps, " \
               "#{"%.0f" % @@renders_per_sec} renders/s, " \
               "#{@players.map(&.renderer.frame_count).sum} frames total")
    end
  end
end

Egui.run(LottieNativeApp.new, title: "egui-cr — lottie NATIVE (rlottie)",
  inspector: :hidden)
