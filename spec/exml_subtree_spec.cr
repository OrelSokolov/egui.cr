# Retained subtrees for custom exml elements (Renderer#custom_subtree_key):
# a `cache: true` panel replays its whole span from the paint cache on
# steady frames, re-runs when any folded input changes (row content,
# hover verdict), and never caches an impure subtree (a repeat or a
# stateful tag inside) or one that cannot store (outside the clip).

require "spec"
require "../src/egui"

SUBTR_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(400.0, 300.0))

# A pure paint-only container + a stateful tag: the purity walk must
# tell them apart by the `cache:` mark.
SUBTR_PAINTS = [] of String

# Fix the paren typo guard: track handler runs vs frames.
SUBTR_RUNS = [] of String

widget :subtr_card, cache: true do |node, ui, ctx, rt, r|
  SUBTR_RUNS << "card"
  # the music_tags panel convention: an appear= attr drives an
  # AppearAnims run keyed "{path}/appear" and marks it used
  if (aname = node.attrs["appear"]?) && (kind = Egui::AppearAnims.kind?(aname))
    id = Egui::Id.from("#{node.path}/appear")
    ctx.memory.appear_anims.drive(id, kind, 0.0, ctx.input.time)
    ctx.memory.use_id(id)
  end
  rect = ui.allocate_space(Egui::Vec2.new(100.0, 50.0))
  ui.painter.rect(rect, 0.0,
    fill: Egui::Color32.rgba(0x11, 0x22, 0x33, 0xFF))
  t = rt.string(node.attrs["text"].not_nil!.sub('{', "").sub('}', ""))
  ui.painter.text(Egui::Pos2.new(rect.min.x, rect.center.y), t, 12.0,
    Egui::Color32.rgba(255, 255, 255))
  r.render_each(node, ui, ctx, rt)
end

widget :subtr_leaf, cache: true do |node, ui, ctx, rt, r|
  rect = ui.allocate_space(Egui::Vec2.new(10.0, 10.0))
  ui.painter.rect(rect, 0.0, fill: Egui::Color32.rgba(0, 0, 0, 0))
end

widget :subtr_bad do |node, ui, ctx, rt, r|
  SUBTR_RUNS << "bad"
  ui.allocate_space(Egui::Vec2.new(10.0, 10.0))
end

# One frame through the REAL renderer entry (#render_routes — it owns
# the per-frame bookkeeping the subtree cache relies on), with the
# fragment wrapped into a routed page.
class SubtrDoc
  getter doc : Egui::Exml::Document

  def initialize(markup : String)
    @doc = Egui::Exml.parse(
      %(<exml><page id="root/root">#{markup}</page></exml>))
  end
end

def subtr_frame(ctx : Egui::Context, markup : String,
                rt : Egui::Exml::Runtime,
                renderer : Egui::Exml::Renderer,
                events : Array(Egui::Event) = [] of Egui::Event,
                time : Float64 = 0.016) : Nil
  doc = Egui::Exml.parse(
    %(<exml><page id="root/root">#{markup}</page></exml>))
  ctx.begin_frame(Egui::RawInput.new(SUBTR_SCREEN, events, time))
  renderer.render_routes(ctx, doc, rt)
  ctx.end_frame
end

describe "exml retained subtrees" do
  it "a pure panel re-runs once, then replays while nothing changes" do
    SUBTR_RUNS.clear
    ctx = Egui::Context.new
    rt = Egui::Exml::Runtime.new
    rt.strings["txt"] = "hello"
    markup = %(<subtr_card text="{txt}"><subtr_leaf/></subtr_card>)
    renderer = Egui::Exml::Renderer.new
    3.times { |i| subtr_frame(ctx, markup, rt, renderer, time: 0.016 * (i + 1)) }
    # frame 1 runs (miss, the window's opening transition may keep a
    # second frame live), the rest replay: no handler runs beyond that
    SUBTR_RUNS.size.should be <= 2
    SUBTR_RUNS.size.should be >= 1
  end

  it "changed store content re-runs the handler" do
    SUBTR_RUNS.clear
    ctx = Egui::Context.new
    rt = Egui::Exml::Runtime.new
    rt.strings["txt"] = "a"
    markup = %(<subtr_card text="{txt}"><subtr_leaf/></subtr_card>)
    renderer = Egui::Exml::Renderer.new
    # the opening window's own transition runs a couple of frames
    # (the subtree gate is global while any animation is live); let it
    # settle first
    6.times { |i| subtr_frame(ctx, markup, rt, renderer, time: 0.016 * (i + 1)) }
    steady = SUBTR_RUNS.size
    rt.strings["txt"] = "b"
    6.times { |i| subtr_frame(ctx, markup, rt, renderer, time: 0.1 + 0.016 * i) }
    # steady frames replay; the changed value re-runs exactly once more
    (steady > 0).should be_true
    SUBTR_RUNS.size.should eq steady + 1
  end

  it "a conditional card re-runs on re-appearance (appear run folds into the key)" do
    SUBTR_RUNS.clear
    ctx = Egui::Context.new
    rt = Egui::Exml::Runtime.new
    rt.bools["show"] = true
    markup = %(<column if="show"><subtr_card text="x" appear="rise"><subtr_leaf/></subtr_card></column>)
    renderer = Egui::Exml::Renderer.new
    # shown: entrance runs (~0.8s rise spring, dt clamped at 1/30),
    # then settle, then replay
    80.times { |i| subtr_frame(ctx, markup, rt, renderer, time: 0.016 * (i + 1)) }
    shown_runs = SUBTR_RUNS.size
    shown_runs.should be > 0
    shown_runs.should be < 80 # replaying at least some frames
    # hidden long enough for the paint-cache entry to go stale (3 gens)
    rt.bools["show"] = false
    5.times { |i| subtr_frame(ctx, markup, rt, renderer, time: 0.2 + 0.016 * i) }
    SUBTR_RUNS.size.should eq shown_runs # nothing rendered while hidden
    # back: the appear run was pruned while hidden — the key differs,
    # the handler MUST run again (the entrance animation replays)
    rt.bools["show"] = true
    6.times { |i| subtr_frame(ctx, markup, rt, renderer, time: 0.3 + 0.016 * i) }
    SUBTR_RUNS.size.should be > shown_runs
  end

  it "an impure subtree (a non-cache tag inside) never caches" do
    SUBTR_RUNS.clear
    ctx = Egui::Context.new
    rt = Egui::Exml::Runtime.new
    markup = %(<subtr_card text="x"><subtr_bad/></subtr_card>)
    renderer = Egui::Exml::Renderer.new
    3.times { |i| subtr_frame(ctx, markup, rt, renderer, time: 0.016 * (i + 1)) }
    # every frame runs for real: the bad child opts the panel out
    SUBTR_RUNS.count("card").should eq 3
    SUBTR_RUNS.count("bad").should eq 3
  end
end
