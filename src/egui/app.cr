# Port of eframe's `epi::App` (egui_upstream/crates/eframe/src/epi.rs):
# the user-facing application trait. `update` runs once per frame with
# the shared Context; Crystal blocks play the role of Rust closures.

module Egui
  abstract class App
    include Reactive

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

    # Debug-only style persistence: call `enable_ecss "my_app"` in the
    # subclass body (the macro lives in `egui/ecss.cr`). In debug
    # builds the runtime inspector then keeps a `.ecss` style-diff file
    # next to the binary (`<bin_dir>/style_my_app.ecss`) — edits are
    # saved to it by the inspector's «Сохранить» button and re-loaded
    # on external changes.
  end
end
