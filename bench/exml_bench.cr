# Headless benchmark of the exml tree walk — the CPU part of a frame
# BEFORE any FFI/GPU work, the same headless harness shape as
# spec/exml_spec.cr's `exml_frame` (Context + begin/end_frame, no
# backend). Measures the per-frame cost of `Renderer#render` over a
# page mixing the three interesting loads:
#
#   * static widgets   — interp early-outs, nothing dynamic
#   * dynamic labels   — `{slot}` interpolation each frame
#   * a 100-row repeat — row scopes + re-pathed subtrees
#
# Three modes:
#
#   native  — the SAME page hand-written in Crystal (ui.label/ui.button
#             straight calls). The apples-to-apples baseline.
#   stable  — exml, nothing in the store moves between frames. The
#             steady state of a real UI: interp cache hits, re-pathed
#             row subtrees memoized.
#   churn   — exml, every store value changes every frame. The interp
#             cache always misses ≈ the pre-cache interpolate cost;
#             row subtrees still hit the memo (row keys are stable).
#
#   crystal build --release bench/exml_bench.cr -o bin/exml_bench \
#     && ./bin/exml_bench

require "../src/egui"

SCREEN = Egui::Rect.new(Egui::Pos2.zero, Egui::Pos2.new(1200.0, 800.0))
FRAMES = 1000

# ~40 static + ~10 dynamic widgets + a 100-row repeat (3 widgets a
# row → ~350 rendered widgets — a notepad-shaped page).
MARKUP = String.build do |s|
  s << %(<page id="bench"><central>)
  40.times { |i| s << %(<label text="static #{i}"/>) }
  10.times { |i| s << %(<label text="dyn #{i}: {status} ({clock})"/>) }
  s << %(<repeat for="item" in="items" key="name">)
  s << %(<row><label text="{item.name}"/><label text="{item.size}"/>)
  s << %(<button text="×" on_click="noop"/></row>)
  s << %(</repeat></central></page>)
end

def frame(ctx : Egui::Context, nodes : Array(Egui::Exml::Node),
          rt : Egui::Exml::Runtime, renderer : Egui::Exml::Renderer,
          time : Float64) : Nil
  ctx.begin_frame(Egui::RawInput.new(SCREEN, [] of Egui::Event, time))
  ctx.central_panel("bench") do |ui|
    nodes.each { |n| renderer.render(n, ui, ctx, rt) }
  end
  ctx.end_frame
end

def seed(rt : Egui::Exml::Runtime) : Nil
  rt.strings["status"] = "ok"
  rt.strings["clock"] = "12:00"
  rt.rows["items"] = ROWS
  rt.actions["noop"] = ->{ nil }
end

ROWS = (0...100).map { |i| {"name" => "document-#{i}", "size" => "#{i} KB"} }

def native_frame(ctx : Egui::Context, rows : Array(Hash(String, String)),
                 status : String, clock : String, time : Float64) : Nil
  ctx.begin_frame(Egui::RawInput.new(SCREEN, [] of Egui::Event, time))
  ctx.central_panel("bench") do |ui|
    40.times { |i| ui.label("static #{i}") }
    10.times { |i| ui.label("dyn #{i}: #{status} (#{clock})") }
    rows.each do |row|
      ui.horizontal do |h|
        h.label(row["name"])
        h.label(row["size"])
        h.button("×")
      end
    end
  end
  ctx.end_frame
end

def run_native : Nil
  ctx = Egui::Context.new
  10.times { |i| native_frame(ctx, ROWS, "ok", "12:00", 0.016 * (i + 1)) }

  t0 = Time.instant
  gc0 = GC.stats.total_bytes
  FRAMES.times do |i|
    native_frame(ctx, ROWS, "ok", "12:00", 0.016 * (11 + i))
  end
  dt = (Time.instant - t0).total_seconds
  per_frame_gc = (GC.stats.total_bytes - gc0).to_f64 / FRAMES

  puts "%-8s %8.1f µs/frame   %10.0f B/frame   (%d frames)" % {
    "native", dt * 1_000_000 / FRAMES, per_frame_gc, FRAMES,
  }
end

def run(label : String, churn : Bool) : Nil
  doc = Egui::Exml.parse(MARKUP)
  rt = Egui::Exml::Runtime.new
  seed(rt)
  renderer = Egui::Exml::Renderer.new
  ctx = Egui::Context.new
  nodes = doc.pages.first.children

  10.times { |i| frame(ctx, nodes, rt, renderer, 0.016 * (i + 1)) } # warmup

  t0 = Time.instant
  gc0 = GC.stats.total_bytes
  FRAMES.times do |i|
    if churn # every slot moves: interp always rebuilds
      rt.strings["status"] = "v#{i}"
      rt.strings["clock"] = "#{i % 60}:#{i % 60}"
      rt.rows["items"] = (0...100).map do |j|
        {"name" => "document-#{j}", "size" => "#{i % 100} KB"}
      end
    end
    frame(ctx, nodes, rt, renderer, 0.016 * (11 + i))
  end
  dt = (Time.instant - t0).total_seconds
  per_frame_gc = (GC.stats.total_bytes - gc0).to_f64 / FRAMES

  puts "%-8s %8.1f µs/frame   %10.0f B/frame   (%d frames)" % {
    label, dt * 1_000_000 / FRAMES, per_frame_gc, FRAMES,
  }
end

puts "exml walk: ~350 widgets/page (40 static + 10 dynamic + 100x3 repeat)"
run_native
run("exml-stable", churn: false)
run("exml-churn", churn: true)
