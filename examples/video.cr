# egui-cr video player demo — a separate binary (bin/video).
#
# Framework side: the egui-cr stream-texture seam
# (TextureRegistry#create_stream / #update / #destroy, backed by the
# sokol shim's SG_USAGE_STREAM images). Demo side: FFmpeg bindings +
# decoder/player + this UI. See videoplayer.md for the full plan.

require "../src/egui/backend_selector"

require "./video/ffmpeg"
require "./video/player"
require "./video/app"

app = VideoApp.new(ARGV[0]?)

Egui.run(app,
  title: "egui-cr — video", width: 960, height: 620, inspector: :hidden)
