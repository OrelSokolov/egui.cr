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
  end
end
