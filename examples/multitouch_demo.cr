# Multitouch Demo — Egui::ImageView with an inline SVG artwork: pan
# with one finger / drag, pinch-zoom with two fingers / wheel,
# double-tap to reset. The gesture pipeline: the sokol shim maps one
# finger to pointer drag (pan) and a two-finger pinch to
# Egui::Event.zoom (see backend/sokol_shim.c, SH_EVENT_PINCH), which
# arrives per frame as ctx.input.zoom_delta / zoom_pos. On the desktop
# the same view works with mouse drag + wheel. All pan/zoom/bucket
# logic lives in the widget (widgets/image_view.cr) — this demo is the
# thin usage reference.
#
# Build (host):  ANDROID_PLATFORM=33 crystal build --cross-compile \
#                 --target=aarch64-linux-android -o multitouch_demo.o \
#                 examples/multitouch_demo.cr
# APK:           tmp/android/build_apk.sh <dir>/multitouch_demo.o
# iOS:           crystal build --cross-compile \
#                 --target=aarch64-apple-darwin \
#                 -o multitouch_demo.o examples/multitouch_demo.cr \
#                 --link-flags "tmp/ios/phase3/libegui_cr_sokol_ios.a"
# App bundle:    tmp/ios/phase4/build_demo.sh <dir>/multitouch_demo.o
#   (swap demo.o for multitouch_demo.o in that script)

require "../src/egui/backend_selector"

class MultitouchDemoApp < Egui::App
  # Inline artwork (no File.read — an APK/.app bundle ships no assets
  # dir). Gradients + nested shapes survive zoom visibly: the farther
  # you zoom in, the more of the ring texture and vignette you see.
  ART = <<-SVG
    <svg viewBox="0 0 240 240" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <radialGradient id="bg" cx="50%" cy="42%" r="70%">
          <stop offset="0%" stop-color="#3b2f63"/>
          <stop offset="100%" stop-color="#12101f"/>
        </radialGradient>
        <linearGradient id="ring" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#7ee0ff"/>
          <stop offset="100%" stop-color="#b16bff"/>
        </linearGradient>
      </defs>
      <rect width="240" height="240" fill="url(#bg)"/>
      <circle cx="120" cy="104" r="78" fill="none" stroke="url(#ring)" stroke-width="10"/>
      <circle cx="120" cy="104" r="60" fill="none" stroke="#ffffff" stroke-opacity="0.25" stroke-width="2"/>
      <circle cx="120" cy="104" r="92" fill="none" stroke="#ffffff" stroke-opacity="0.12" stroke-width="1"/>
      <path d="M120 40 L188 156 L52 156 Z" fill="#ff5d73" fill-opacity="0.9"/>
      <rect x="86" y="72" width="68" height="68" rx="10"
            fill="#2fbf71" fill-opacity="0.85"/>
      <circle cx="120" cy="104" r="24" fill="#ffd23f"/>
      <circle cx="120" cy="188" r="14" fill="#7ee0ff"/>
      <circle cx="48" cy="40" r="8" fill="#b16bff"/>
      <circle cx="196" cy="204" r="6" fill="#ff5d73"/>
    </svg>
  SVG

  # Drawn size (points) at scale 1.0 — square, matching the artwork's
  # aspect.
  BASE = 300.0

  @view : Egui::ImageView

  def initialize
    super
    svg = Egui::Svg.new(ART, Egui::Vec2.new(BASE, BASE))
    @view = Egui::ImageView.new("art", svg, Egui::Vec2.new(BASE, BASE))
  end

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("Multitouch — pinch to zoom")
      ui.label("1 finger / drag: pan · 2 fingers / wheel: zoom · double-tap: reset")
      ui.label("zoom: #{(@view.scale * 100.0).round.to_i}%  " \
               "offset: (#{@view.offset.x.round(1)}, #{@view.offset.y.round(1)})  " \
               "FPS: #{"%.1f" % ui.ctx.fps}")
      if ui.button("Reset").clicked?
        @view.reset
      end
      ui.separator

      # The whole canvas: allocate, gestures, bucket-baked artwork,
      # startup prewarm — all inside the widget.
      @view.ui(ui)
    end
  end
end

Egui.run(MultitouchDemoApp.new, title: "egui-cr — Multitouch Demo")
