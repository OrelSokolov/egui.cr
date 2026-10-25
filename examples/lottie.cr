# Lottie demo — real animated vector assets through the rlottie shim
# (backend/rlottie.cr): the chat-emoji row is Google's animated Noto
# emoji (assets/lottie/emoji/, fetched from the Google Fonts CDN — see
# the LICENSE note there). Play/pause and speed drive every player at
# once; each keeps its own clock, so the row stays unsynchronized —
# like a live chat feed.
#
# Build (the rlottie shim is behind the LOTTIE feature flag):
#   rake download:rlottie
#   LOTTIE=1 rake build:dev[lottie]

require "../src/egui/backend_selector"
require "../src/egui/backend/rlottie"

class LottieApp < Egui::App
  EMOJI = [{"1f600", "grinning"}, {"1f602", "tears of joy"},
           {"1f622", "crying"}, {"1f60d", "heart eyes"},
           {"1f44d", "thumbs up"}, {"1f525", "fire"},
           {"1f389", "party"}, {"2764", "heart"}]

  @players : Array(Egui::Lottie::Player)
  @speed : Float64 = 1.0

  def initialize
    super()
    @players = EMOJI.map do |codepoint, _name|
      anim = Egui::Backend::Rlottie::Animation
        .from_json(File.read("assets/lottie/emoji/#{codepoint}.json"))
      raise "rlottie rejected #{codepoint}" unless anim
      player = Egui::Lottie::Player.new(anim)
      player.play
      player
    end
  end

  def update(ctx : Egui::Context) : Nil
    # Playing animations need continuous repaints — on-demand mode
    # would freeze the clocks between interactions.
    ctx.request_repaint if @players.any?(&.playing?)

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
      ui.label("Noto animated emoji (Google) — #{"%.1f" % @players.first.renderer.fps} fps, " \
               "#{@players.map(&.renderer.frame_count).sum} frames total")
    end
  end
end

Egui.run(LottieApp.new, title: "egui-cr — lottie",
  inspector: :hidden)
