# Port of eframe's `epi::App` (egui_upstream/crates/eframe/src/epi.rs):
# the user-facing application trait. `update` runs once per frame with
# the shared Context; Crystal blocks play the role of Rust closures.

module Egui
  abstract class App
    getter ctx : Context

    def initialize
      @ctx = Context.new
    end

    abstract def update(ctx : Context) : Nil

    # The app's global theme — delegates to the Context so the whole UI
    # restyles the frame after `theme = Egui::Theme.light`.
    def theme : Theme
      @ctx.theme
    end

    def theme=(theme : Theme) : Theme
      @ctx.theme = theme
    end
  end
end
