# Generate the Lottie twin-verification dataset (spec/dataset/lottie/)
# from the rlottie C shim: for every asset, dump the evaluated scene
# graph (render_tree — pre-rasterization geometry, paints, gradients,
# masks) at frames {0, 1/4, 1/2, 3/4, last} into JSON, plus a manifest
# with exact metadata (w/h/fps/frames/duration — the port must match
# those STRICTLY; coordinates are compared within a float epsilon, see
# plans/lottie-port.md).
#
# Run (needs the LOTTIE=1 native build):
#   LOTTIE=1 rake build:native
#   crystal run scripts/make_lottie_dataset.cr --link-flags \
#     "-Llib -Llib/rlottie -legui_cr_sokol -legui_cr_rlottie -lrlottie -lc++ \
#      -framework Cocoa -framework OpenGL -framework QuartzCore \
#      -framework AVFoundation -framework CoreMedia -framework IOKit"
#
# Regenerating overwrites the whole spec/dataset/lottie/ directory —
# commit the result (it is the golden contract for the port).

require "file_utils"
require "json"

@[Link("egui_cr_rlottie")]
@[Link("rlottie")]
lib LibShim
  fun from_data = egui_cr_lottie_from_data(data : UInt8*, key : UInt8*) : Void*
  fun free_anim = egui_cr_lottie_free(animation : Void*) : Nil
  fun size = egui_cr_lottie_size(animation : Void*, w : LibC::SizeT*,
                                 h : LibC::SizeT*) : Nil
  fun framerate = egui_cr_lottie_framerate(animation : Void*) : Float64
  fun total_frames = egui_cr_lottie_total_frames(animation : Void*) : LibC::SizeT
  fun duration = egui_cr_lottie_duration(animation : Void*) : Float64
  fun dump_tree = egui_cr_lottie_dump_tree(animation : Void*, frame : LibC::SizeT,
                                           w : LibC::SizeT, h : LibC::SizeT) : UInt8*
  fun free_dump = egui_cr_lottie_free_dump(dump : UInt8*) : Nil
end

OUT = File.join(__DIR__, "..", "spec", "dataset", "lottie")

def build_key(str : String) : String
  "egui-cr-lottie-#{str.hash}"
end

# (name, path) — spinner first: the hand-crafted minimal contract, then
# the real Noto emoji (assets/lottie/emoji/README.md for provenance).
ASSETS = [{"spinner", "assets/lottie/spinner.json"}] +
         Dir["assets/lottie/emoji/*.json"].sort.map do |p|
           {"emoji/#{File.basename(p, ".json")}", p}
         end

FileUtils.rm_rf(OUT)
FileUtils.mkdir_p(OUT)

manifest = [] of NamedTuple(file: String, w: Int32, h: Int32, fps: Float64,
  frames: Int32, duration: Float64, dumps: Array(String))

ASSETS.each do |name, path|
  json = File.read(path)
  anim = LibShim.from_data(json.to_unsafe, build_key(json).to_unsafe)
  raise "rlottie rejected #{path}" if anim.null?
  w = uninitialized LibC::SizeT
  h = uninitialized LibC::SizeT
  LibShim.size(anim, pointerof(w), pointerof(h))
  frames = LibShim.total_frames(anim).to_i
  fps = LibShim.framerate(anim)
  duration = LibShim.duration(anim)
  LibShim.free_anim(anim)

  # Frame sample points; dedup + sort keeps tiny assets sane.
  sample = {0, frames // 4, frames // 2, (3 * frames) // 4,
            frames > 0 ? frames - 1 : 0}.to_a.uniq.sort

  dumps = [] of String
  sample.each do |frame|
    # A FRESH animation per frame: rlottie's Layer::update returns
    # before updating an invisible layer's content, so a reused
    # instance leaks the previous frame's geometry into the dump for
    # layers that just left their ip/op window (visible in 1f622's
    # f110: the st:-8 precomp's children kept their f83 state). The
    # twin contract is STATELESS per-frame evaluation — the port
    # (and the pixel A/B) never renders stale content.
    anim = LibShim.from_data(json.to_unsafe, build_key(json).to_unsafe)
    raise "rlottie rejected #{path}@#{frame}" if anim.null?
    dump = LibShim.dump_tree(anim, frame.to_u64, w, h)
    LibShim.free_anim(anim)
    raise "render_tree failed for #{name}@#{frame}" if dump.null?
    tree = String.new(dump)
    LibShim.free_dump(dump)
    # Wrap the raw tree with the identity of the sample: the replaying
    # spec knows WHAT to parse and WHAT the port must reproduce.
    file_name = "#{name.tr("/", "_")}.f#{frame}.json"
    File.write(File.join(OUT, file_name),
      %({"asset":"#{name}","frame":#{frame},"size":[#{w},#{h}],\n) +
      %("tree":#{tree}\n}\n))
    dumps << file_name
    puts "#{name}@#{frame}: #{tree.bytesize} bytes"
  end
  manifest << {file: name, w: w.to_i, h: h.to_i, fps: fps,
    frames: frames, duration: duration, dumps: dumps}
end

File.write(File.join(OUT, "manifest.json"), manifest.to_json)
puts "\n#{ASSETS.size} assets, #{manifest.sum(&.[:dumps].size)} dumps -> #{OUT}"
