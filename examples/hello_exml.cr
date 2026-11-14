# hello_exml.cr — hello.cr's UI driven through the exml pipeline
# (markup: assets/hello.exml). The controlled A/B twin of
# examples/hello.cr: same widgets, same always-repaint FPS meter —
# the FPS delta between bin/apps/hello and bin/apps/hello_exml is the
# per-frame cost of the exml machinery itself (dynamic {…} attr
# re-interpolation, subtree-cache key building, style resolution).
# Запуск: rake build:dev[hello_exml] && ./bin/apps/hello_exml

require "../src/egui/driver_selector"

class HelloExmlApp < Egui::App
  @count = 0
  @exml : Egui::Exml::Document
  @renderer = Egui::Exml::Renderer.new
  getter rt : Egui::Exml::Runtime

  # GC telemetry, как у hello (аллокации/кадр — первая подозреваемая
  # цена exml-интерполяции: строки {…} пересобираются каждый кадр).
  @gc_prev = GC.stats
  @gc_collections = 0

  def self.exml_path : String
    env = ENV["HELLO_EXML"]?
    return env if env && File.exists?(env)
    root = File.dirname(__DIR__) # examples/ → корень проекта
    c = File.join(root, "assets", "hello.exml")
    return c if File.exists?(c)
    raise "assets/hello.exml not found (set HELLO_EXML)"
  end

  def initialize
    super
    @exml = Egui::Exml::Document.load(self.class.exml_path)
    @rt = Egui::Exml::Runtime.new
  end

  def update(ctx : Egui::Context) : Nil
    # Раз в процесс: регистрируем действия разметки (on_click="inc").
    unless @rt.actions["inc"]?
      @rt.actions["inc"] = ->{ @count += 1 }
      @rt.actions["quit"] = ->{ Egui::SystemPorts::Quit.quit! }
    end

    @exml.reload_if_changed

    # Store → разметка: живые значения для {…}-интерполяции.
    @rt.strings["count"] = @count.to_s
    @rt.strings["fps"] = "%.1f" % ctx.fps
    st = GC.stats
    alloc = st.total_bytes - @gc_prev.total_bytes
    @gc_collections += 1 if st.bytes_since_gc < @gc_prev.bytes_since_gc
    @rt.strings["gc"] = "#{@gc_collections} collections, " \
                        "#{"%.1f" % (alloc / 1024.0)} KiB/frame"
    @gc_prev = st

    # Как у hello: живой FPS-метр требует живые кадры.
    ctx.request_repaint
    @renderer.render_routes(ctx, @exml, @rt)
  end
end

Egui.run(HelloExmlApp.new, title: "egui-cr — hello (exml)",
  inspector: :hidden)
