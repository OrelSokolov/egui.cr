# egui-cr slice 1: Hello World — button + label + label change.
#
# The Rust egui equivalent:
#
#   egui::CentralPanel::default().show(ctx, |ui| {
#       ui.label("Hello World!");
#       if ui.button("Click me").clicked() {
#           count += 1;
#       }
#       ui.label(format!("count: {}", count));
#   });

require "../src/egui"
require "../src/egui/backend/sokol"

class HelloApp < Egui::App
  @count = 0
  @opened : String? = nil

  # GC telemetry: allocation delta per frame + collection counter
  # (GC.stats has no collection count, so detect a GC run by the
  # bytes_since_gc counter resetting between frames).
  @gc_prev = GC.stats
  @gc_collections = 0

  def update(ctx : Egui::Context) : Nil
    # Movable window: drag the title bar (window position is system
    # state — Areas), the body content sits below it.
    ctx.window("Hello egui-cr", Egui::Pos2.new(40.0, 40.0), width: 360.0) do |ui|
      ui.heading("Hello World!")

      # System ports demo: native dialogs + cross-platform exit. The
      # dialog call never blocks the frame — the picker runs in its own
      # fiber (AsyncDialogs) and the path arrives in the callback on a
      # later frame; meanwhile the UI keeps rendering ("opening…" row).
      if ui.button("Open file…").clicked?
        @opened = nil
        Egui::SystemPorts::OpenFileDialog.show(
          filters: ["*.png", "*.jpg"]) { |path| @opened = path }
      end
      if Egui::SystemPorts::AsyncDialogs.pending?
        ui.label("opening…")
      else
        ui.label("opened: #{@opened || "—"}")
      end

      if ui.button("Quit").clicked?
        Egui::SystemPorts::Quit.quit!
      end

      # CollapsingHeader: open/closed flag is system state (IdTypeMap),
      # not app state — try collapsing and watch it survive.
      Egui::CollapsingHeader.new("Demo", default_open: true).show(ui) do |body|
        if body.button("Click me").clicked?
          @count += 1
        end
        body.label("Clicked #{@count} times")
      end
    end

    # FPS + GC telemetry panel pinned to the bottom of the screen.
    # Immediate mode allocates geometry every frame; in Crystal that
    # lands on the Boehm GC, so watch alloc/frame and collection
    # frequency (a spike in collections mid-frame = stutter risk).
    ctx.bottom_panel("fps") do |ui|
      ui.label("FPS: #{"%.1f" % ctx.fps}  (frame #{(ctx.input.dt * 1000).round(1)} ms)")

      st = GC.stats
      alloc = st.total_bytes - @gc_prev.total_bytes
      @gc_collections += 1 if st.bytes_since_gc < @gc_prev.bytes_since_gc
      ui.label(
        "GC: #{@gc_collections} collections, #{"%.1f" % (alloc / 1024.0)} KiB/frame, " \
        "heap #{"%.1f" % (st.heap_size / 1024.0 / 1024.0)} MiB (#{"%.0f" % (st.free_bytes / 1024.0)} KiB free)"
      )
      @gc_prev = st
    end
  end
end

Egui::Backend::Sokol.run(HelloApp.new, title: "egui-cr — hello")
