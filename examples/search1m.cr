# egui-cr search1m — the 1M-line twin of chat/100k: a synthetic text
# file ("hello, this is line #N from 1 million text file") generated
# in memory (N= env, default 1_000_000; N=10000000 for the 10M leg),
# rendered through a VISIBLE BAND — per frame only the rows on screen
# are laid out (a fixed row pitch, two bulk skips for everything
# above and below), so a million lines scroll at frame rate with the
# CPU cost of ~50 labels. Target: a steady 200+ fps (vsync off,
# `EGUI_VSYNC=1` puts it back).
#
# The FILTER is a RING SEARCH built as a PARALLEL MAP: the corpus is
# cut into one line range per worker, every range maps to its
# Array(Int32) of matched line numbers (a monotonic String#index
# scan, see examples/search1m_components/corpus.cr), and the chunks
# concatenate in order. Built with -Dexecution_context (Crystal 1.21,
# the Rakefile rule adds it) the map runs as fibers on a real
# Fiber::ExecutionContext::Parallel pool — a 50 MB scan splits across
# all cores and lands in a few ms. Every keystroke bumps an atomic
# generation: superseded chunks drop their result at the boundary,
# so typing never queues work — the newest search always wins. (A
# no-flag build falls back to a sequential chunked scan that yields
# between slices, same ring semantics.)
#
# The chrome is exml (assets/search1m.exml): the field, the stats
# line and the fps counter are markup; <line_list/> is this binary's
# custom element. Bench numbers: bench/search1m_bench.cr.
#
#   rake build:release[search1m] && ./bin/apps/search1m
#   N=10000000 ./bin/apps/search1m

require "../src/egui/driver_selector"
require "./search1m_components/corpus"

N = (ENV["N"]? || "1000000").to_i

class Search1MApp < Egui::App
  LIST_SCROLL = Egui::Id.from("search1m/list")

  {% if flag?(:execution_context) %}
    # The parallel map's worker count (CRYSTAL_WORKERS= overrides).
    WORKERS = Fiber::ExecutionContext.default_workers_count
  {% else %}
    WORKERS = 1
    # Sequential fallback slice: lines per search chunk (~3.5 MB, a
    # low-ms scan — frames keep coming between slices).
    CHUNK = 65_536
  {% end %}

  getter corpus : SearchCorpus
  getter total : Int32
  # Matched line indices (the parallel map's merged result, or the
  # streaming partials of the sequential fallback).
  property filtered = [] of Int32
  getter query = ""
  getter scanned = 0
  getter? search_done = true
  @search_ms = 0.0
  @list_ms = 0.0
  # Ring generation (atomic: parallel workers read it cross-thread):
  # the newest keystroke's search wins, older ones drop their result.
  @gen = Atomic(Int32).new(0)
  {% if flag?(:execution_context) %}
    @pool : Fiber::ExecutionContext::Parallel? = nil
  {% end %}

  @exml : Egui::Exml::Document
  @renderer = Egui::Exml::Renderer.new
  @rt = Egui::Exml::Runtime.new

  # Locate the markup: EGUI_EXML= env override, then the repo checkout
  # (__DIR__/../assets), then the working directory — in that order.
  def self.exml_path : String
    [ENV["EGUI_EXML"]?, File.join(__DIR__, "..", "assets", "search1m.exml"),
     File.join("assets", "search1m.exml")].compact.each do |c|
      return c if File.file?(c)
    end
    File.join("assets", "search1m.exml")
  end

  def initialize
    super
    ctx.theme = Egui::Theme.dark

    t0 = Time.instant
    @corpus = SearchCorpus.new(N)
    @total = @corpus.total
    STDERR.printf("search1m: %d lines, %.1f MB in %.0f ms\n",
      @total, @corpus.buf.bytesize / 1_048_576.0,
      (Time.instant - t0).total_milliseconds)

    @exml = Egui::Exml::Document.load(self.class.exml_path)
    Egui::Exml.validate(@exml, known_custom: %w(line_list))
      .each { |i| STDERR.puts "exml: #{i}" }
    @rt.actions["search"] = ->{ start_search(@rt.string("query")) }
    @renderer.on("line_list") do |_node, ui, _ctx, _rt, _r|
      render_list(ui)
    end
    @rt.bools["continuous"] = true
  end

  # --- the ring search ----------------------------------------------------

  def start_search(text : String) : Nil
    gen = @gen.add(1) + 1 # any running search dies at its boundary
    @query = text
    @filtered.clear
    @scanned = 0
    @search_ms = 0.0
    # A fresh result set starts from the top of the list.
    ctx.memory.data.set_vec2(LIST_SCROLL, Egui::Vec2.new(0.0, 0.0))
    if text.empty?
      @scanned = @total
      @search_done = true
      ctx.request_repaint
      return
    end
    @search_done = false
    t0 = Time.instant
    {% if flag?(:execution_context) %}
      parallel_search(text, gen, t0)
    {% else %}
      sequential_search(text, gen, t0)
    {% end %}
  end

  # The PARALLEL MAP: one line range per worker, each scanned on the
  # pool (real threads — this is the whole point of execution
  # contexts), results collected through a buffered channel sized to
  # the chunk count so workers never block. The collector runs in
  # the DEFAULT context (parallelism 1): it can never execute at the
  # same time as the UI fiber, so publishing into @filtered needs no
  # lock. A superseded generation drops its result; its workers still
  # finish into their own channel and get collected away silently.
  {% if flag?(:execution_context) %}
    private def parallel_search(text : String, gen : Int32, t0 : Time::Instant) : Nil
      pool = @pool ||= Fiber::ExecutionContext::Parallel.new("search1m", WORKERS)
      ranges = @corpus.chunks(WORKERS)
      ch = Channel(Tuple(Int32, Array(Int32))).new(ranges.size)
      ranges.each_with_index do |(c0, c1), k|
        pool.spawn(name: "search1m/#{k}") do
          next if @gen.get != gen
          results = @corpus.scan_range(text, c0, c1)
          ch.send({k, results}) if @gen.get == gen
        end
      end
      spawn do # collector: ordered merge, publish once
        slots = Array(Array(Int32)?).new(ranges.size, nil)
        ranges.size.times do
          k, batch = ch.receive
          slots[k] = batch
        end
        next unless @gen.get == gen && !@search_done
        merged = Array(Int32).new(@total // 4 + 16)
        slots.each { |b| merged.concat(b.not_nil!) }
        @filtered = merged
        @scanned = @total
        @search_done = true
        @search_ms = (Time.instant - t0).total_milliseconds
        ctx.request_repaint
      end
    end
  {% end %}

  # Sequential fallback (a no-flag build): one cooperative chunk per
  # few ms, partial results streaming into the list — same ring
  # semantics at the chunk boundary.
  {% unless flag?(:execution_context) %}
    private def sequential_search(text : String, gen : Int32, t0 : Time::Instant) : Nil
      corpus = @corpus
      total = @total
      spawn do
        c = 0
        while c < total
          break if @gen.get != gen
          last = {c + CHUNK, total}.min
          @filtered.concat(corpus.scan_range(text, c, last))
          c = last
          @scanned = c
          @search_ms = (Time.instant - t0).total_milliseconds
          ctx.request_repaint # stream partial results into the list
          sleep 1.millisecond # cooperative: frames keep coming
        end
        if @gen.get == gen
          @search_done = true
          @search_ms = (Time.instant - t0).total_milliseconds
          ctx.request_repaint
        end
      end
    end
  {% end %}

  # --- the list: a visible band over n rows --------------------------------

  # Fixed row pitch (one label per row, no wrap): the first visible
  # row is a division, everything above and below is two bulk
  # allocate_space skips — the same O(visible) geometry chat/100k's
  # Fenwick binary search provides, without needing the tree at all.
  private def render_list(ui : Egui::Ui) : Nil
    t0 = Time.instant
    rows = @filtered
    n = @query.empty? ? @total : rows.size
    Egui::ScrollArea.new(id: LIST_SCROLL).show(ui) do |scroll|
      style = scroll.style
      line_h = style.font_size * Egui::Fonts::LINE_H_FACTOR
      gap = style.spacing.item_spacing.y
      pitch = line_h + gap
      clip = scroll.painter.clip
      base = scroll.cursor.y

      lo = {((clip.min.y - base) / pitch).floor.to_i, 0}.max.clamp(0, n)
      scroll.allocate_space(Egui::Vec2.new(0.0, lo * pitch - gap)) if lo > 0

      row = lo
      while row < n
        break if scroll.cursor.y > clip.max.y
        idx = @query.empty? ? row : rows.unsafe_fetch(row)
        scroll.label("##{idx + 1}  #{@corpus.line(idx)}",
          wrap: false, userselect: false)
        row += 1
      end

      if row < n # bulk-skip whatever remains below the viewport
        scroll.allocate_space(
          Egui::Vec2.new(0.0, {(n - row) * pitch - gap, 0.0}.max))
      end
    end
    @list_ms = (Time.instant - t0).total_milliseconds
  end

  # --- the frame -----------------------------------------------------------

  def update(ctx : Egui::Context) : Nil
    @exml.reload_if_changed
    ctx.request_repaint if @rt.bool("continuous")
    sync_store(ctx)
    @renderer.render_routes(ctx, @exml, @rt)
  end

  private def sync_store(ctx : Egui::Context) : Nil
    s = @rt.strings
    s["total"] = self.class.fmt(@total)
    shown = @query.empty? ? @total : @filtered.size
    pct = @total.zero? ? 100 : @scanned * 100 // @total
    mode = {% if flag?(:execution_context) %} "parallel ×#{WORKERS}" {% else %} "sequential" {% end %}
    s["stats"] = "found: #{self.class.fmt(shown)} · scanned: #{pct}%" \
                 " · search: #{"%.1f" % @search_ms} ms (#{mode})" \
                 " · list: #{"%.2f" % @list_ms} ms"
    s["fps"] = "fps #{"%.0f" % ctx.fps} · frame #{"%.2f" % (ctx.input.dt * 1000)} ms"
  end

  def self.fmt(n : Int) : String
    s = n.to_s
    String.build(s.size + s.size // 3) do |io|
      s.each_char_with_index do |ch, i|
        io << ch
        r = s.size - i - 1
        io << ' ' if r > 0 && r % 3 == 0
      end
    end
  end
end

app = Search1MApp.new
Egui.run(app, title: "search1m — #{N} lines · ring filter",
  width: 980, height: 640, vsync: ENV["EGUI_VSYNC"]? == "1",
  inspector: :hidden)
