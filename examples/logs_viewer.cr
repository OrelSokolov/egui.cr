# egui-cr LogsViewer — the search1m engine pointed at real logs:
# a visible-band list over a million+ lines (LineIndex, O(visible)
# per frame) with a FILTER that combines (AND):
#
#   * level chips — a MULTI-toggle (INFO + ERROR at once is fine),
#     rendered from the JSON config, so the quick-filter set is
#     cross-platform user data, not code;
#   * a regex line — literal text (no metachars) takes the memmem
#     fast path (milliseconds over 1M lines); a real regex compiles
#     once and is matched per line; an invalid pattern keeps the
#     previous result and shows the error.
#
# The filter runs as the search1m ring job: built with
# -Dexecution_context (the Rakefile rule adds it) it is a parallel
# map over an ExecutionContext::Parallel pool — one line range per
# worker, ordered merge through a channel; every change bumps an
# atomic generation and superseded jobs drop their result. A no-flag
# build falls back to a sequential chunked scan with the same ring
# semantics.
#
# File sources: the Open… button (native dialog, never blocks a
# frame), a path on the command line (logs_viewer app.log), and the
# last opened file (also persisted). No file at hand — a synthetic
# demo log boots instead, so the benchmark story works out of the
# box. Loading indexes off the UI's back: chunked reads with
# cooperative yields, level classification with progress callbacks.
#
# Config (~/.config/logs_viewer/settings.json et al., AppConfig):
#   {"levels": [{"name": "INFO", "color": "#5FAFFF", "enabled": true},
#               …], "regex": "", "last_file": null}
# — edit the chips there; `enabled` is the live toggle state.
#
#   rake build:release[logs_viewer] && ./bin/apps/logs_viewer
#   N=10000000 ./bin/apps/logs_viewer        # demo-log size

{% unless env("EGUI_EMBEDDED") %}require "../src/egui/driver_selector"{% end %}
require "./logs_viewer_components/log_store"

DEMO_N = (ENV["N"]? || "1000000").to_i

class LogsViewerApp < Egui::App
  APP_ID = "logs_viewer"
  LIST_SCROLL = Egui::Id.from("logs_viewer/list")

  {% if flag?(:execution_context) %}
    WORKERS = Fiber::ExecutionContext.default_workers_count
  {% else %}
    WORKERS = 1
    CHUNK = 65_536 # sequential fallback slice (lines per chunk)
  {% end %}

  # --- the cross-platform JSON config ------------------------------------

  class LevelDef
    include JSON::Serializable

    property name : String
    property color : String  # "#RRGGBB"
    property enabled : Bool = true

    def initialize(@name : String, @color : String, @enabled : Bool = true)
    end
  end

  DEFAULT_LEVELS = [
    LevelDef.new("DEBUG", "#8A8A8A", enabled: false),
    LevelDef.new("INFO", "#5FAFFF", enabled: true),
    LevelDef.new("WARNING", "#FFB84D", enabled: true),
    LevelDef.new("ERROR", "#E9504C", enabled: true),
  ]

  class Settings
    include JSON::Serializable

    property levels : Array(LevelDef)
    property regex : String = ""
    property last_file : String? = nil
    property? bench : Bool = true # the fps/filter HUD lines

    def initialize(@levels : Array(LevelDef) = DEFAULT_LEVELS,
                   @regex : String = "", @last_file : String? = nil,
                   @bench : Bool = true)
    end
  end

  # One level's parsed palette (hex → the gradient/fill variants the
  # chips and the row colors need).
  struct LevelColors
    getter on_grad : Egui::Gradient   # lit chip: bright → dark level color
    getter off_grad : Egui::Gradient  # dim chip: dark neutral plate
    getter off_stroke : Egui::Color32
    getter text : Egui::Color32
    getter text_dim : Egui::Color32   # list rows keep level-colored text

    WHITE = Egui::Color32.rgb(0xFF, 0xFF, 0xFF)

    def initialize(hex : String)
      h = hex.lchop('#')
      r = h[0, 2].to_i?(16) || 0x88
      g = h[2, 2].to_i?(16) || 0x88
      b = h[4, 2].to_i?(16) || 0x88
      # top stop brightened toward white, bottom stop darkened — the
      # classic glossy button ramp
      top = Egui::Color32.rgba(
        {r * 4 // 5 + 51, 255}.min, {g * 4 // 5 + 51, 255}.min,
        {b * 4 // 5 + 51, 255}.min, 255)
      bottom = Egui::Color32.rgba(r * 3 // 5, g * 3 // 5, b * 3 // 5, 255)
      @on_grad = Egui::Gradient.new(:linear,
        [Egui::Gradient::Stop.new(0.0, top),
         Egui::Gradient::Stop.new(1.0, bottom)], 180.0)
      @off_grad = Egui::Gradient.new(:linear,
        [Egui::Color32.rgba(38, 42, 52, 255),
         Egui::Color32.rgba(24, 27, 35, 255)].map_with_index { |c, i|
          Egui::Gradient::Stop.new(i.to_f64, c) }, 180.0)
      @off_stroke = Egui::Color32.rgba(r, g, b, 130)
      @text = Egui::Color32.rgba(r, g, b, 255)
      @text_dim = Egui::Color32.rgba(
        {r // 2 + 0x60, 255}.min, {g // 2 + 0x60, 255}.min,
        {b // 2 + 0x60, 255}.min, 255)
    end
  end

  getter store : LogStore?
  getter rows = [] of Int32 # filtered line indices (the ring result)
  getter? filtering = false
  @filter_ms = 0.0
  @list_ms = 0.0
  @load_status = ""
  @regex_error : String? = nil
  @gen = Atomic(Int32).new(0) # ring generation: the newest filter wins
  @colors : Array(LevelColors)
  @settings : Settings
  {% if flag?(:execution_context) %}
    @pool : Fiber::ExecutionContext::Parallel? = nil
  {% end %}

  @exml : Egui::Exml::Document
  @renderer = Egui::Exml::Renderer.new
  @rt = Egui::Exml::Runtime.new

  def self.exml_path : String
    [ENV["EGUI_EXML"]?, File.join(__DIR__, "..", "assets", "logs_viewer.exml"),
     File.join("assets", "logs_viewer.exml")].compact.each do |c|
      return c if File.file?(c)
    end
    File.join("assets", "logs_viewer.exml")
  end

  def initialize(files : Array(String) = [] of String)
    super()
    ctx.theme = Egui::Theme.dark
    @settings = Egui::SystemPorts::AppConfig.load(APP_ID, Settings.new)
    @colors = @settings.levels.map { |lv| LevelColors.new(lv.color) }

    @exml = Egui::Exml::Document.load(self.class.exml_path)
    Egui::Exml.validate(@exml, known_custom: %w(levels_bar log_list))
      .each { |i| STDERR.puts "exml: #{i}" }
    @rt.actions["open"] = ->{ open_dialog }
    @rt.actions["open_multiple"] = ->{ open_dialog_multiple }
    @rt.actions["toggle_bench"] = ->{
      @settings.bench = !@settings.bench?
      save_settings
      ctx.request_repaint
    }
    @rt.actions["regex_changed"] = ->{
      @settings.regex = @rt.string("regex")
      save_settings
      refilter
    }
    @renderer.on("levels_bar") { |_n, ui, _c, _r, _x| render_level_chips(ui) }
    @renderer.on("log_list") { |_n, ui, _c, _r, _x| render_list(ui) }
    @rt.bools["continuous"] = true
    @rt.strings["regex"] = @settings.regex

    # Boot source: a file argument wins, then the persisted last
    # file, else the synthetic demo log (the benchmark story).
    path = files.first? || @settings.last_file
    if path && File.file?(path)
      load_file(path)
    else
      t0 = Time.instant
      @store = LogStore.generate_demo(
        @settings.levels.map(&.name), DEMO_N)
      @load_status = "demo log: #{self.class.fmt(@store.not_nil!.total)} lines, " \
                     "generated in #{"%.0f" % (Time.instant - t0).total_milliseconds} ms"
      refilter
    end
  end

  private def save_settings : Nil
    Egui::SystemPorts::AppConfig.save(APP_ID, @settings)
  end

  # --- opening files ------------------------------------------------------

  private def open_dialog : Nil
    Egui::SystemPorts::OpenFileDialog.show(
      title: "Open log", filters: [] of String) do |path|
      load_file(path) if path
    end
  end

  # Multi-pick: several log files merge into ONE view (the multi-source
  # grep idiom) — same chunked reader, one store, the status bar names
  # the first file plus a count.
  private def open_dialog_multiple : Nil
    Egui::SystemPorts::OpenFileDialog.show_multiple(
      title: "Open logs", filters: [] of String) do |paths|
      load_files(paths) if paths && !paths.empty?
    end
  end

  # Chunked read + classification with cooperative yields — a 500 MB
  # log loads without freezing the frame loop.
  def load_file(path : String) : Nil
    load_files([path])
  end

  def load_files(paths : Array(String)) : Nil
    label = paths.size == 1 ? paths.first : "#{paths.first} (+#{paths.size - 1})"
    @gen.add(1) # cancel any running filter over the old store
    @load_status = "opening #{label}…"
    ctx.request_repaint
    spawn do
      begin
        t0 = Time.instant
        total_bytes = paths.sum { |p| {File.size(p).to_i, 4096}.max }
        text = String.build(capacity: total_bytes) do |io|
          paths.each_with_index do |path, i|
            io << '\n' if i > 0
            File.open(path, "rb") do |f|
              chunk = Bytes.new(1 << 22) # 4 MB
              while (r = f.read(chunk)) > 0
                io.write(chunk[0, r])
                sleep 0.milliseconds # let frames through
              end
            end
          end
        end
        read_ms = (Time.instant - t0).total_milliseconds
        t1 = Time.instant
        store = LogStore.from_text(
          text, @settings.levels.map(&.name), label) do |done, total|
          @load_status = "indexing #{label}: #{"%.0f" % (done * 100.0 / {total, 1}.max)}%"
          ctx.request_repaint
          sleep 0.milliseconds
        end
        index_ms = (Time.instant - t1).total_milliseconds
        @store = store
        @settings.last_file = paths.first
        save_settings
        @load_status = "#{label}: #{self.class.fmt(store.total)} lines, " \
                       "read #{"%.0f" % read_ms} ms + index #{"%.0f" % index_ms} ms"
        refilter
      rescue e : File::Error | IO::Error
        @load_status = "failed to open #{label}: #{e.message}"
        ctx.request_repaint
      end
    end
  end

  # --- the filter ring job -------------------------------------------------

  REGEX_META = ".*+?()[]{}|^$\\"

  def toggle_level(i : Int32) : Nil
    lv = @settings.levels[i]
    lv.enabled = !lv.enabled
    save_settings
    refilter
  end

  # rows = lines whose level chip is ON (unclassified lines pass only
  # when every chip is on — an untouched filter shows everything) AND
  # which match the regex line (literal text takes the memmem fast
  # path; an invalid regex keeps the previous rows).
  def refilter : Nil
    return unless (store = @store)
    gen = @gen.add(1) + 1
    @rows.clear
    @filtering = true
    @filter_ms = 0.0
    ctx.memory.data.set_vec2(LIST_SCROLL, Egui::Vec2.new(0.0, 0.0))

    regex_text = @settings.regex
    literal = !regex_text.empty? &&
              !regex_text.each_char.any? { |ch| REGEX_META.includes?(ch) }
    re : Regex? = nil
    if !regex_text.empty? && !literal
      begin
        re = Regex.new(regex_text)
        @regex_error = nil
      rescue e : Regex::Error
        @regex_error = e.message.to_s
        @filtering = false
        ctx.request_repaint
        return
      end
    else
      @regex_error = nil
    end

    # level mask: index 0 = unclassified (passes only unfiltered)
    mask = [@settings.levels.all?(&.enabled)] +
           @settings.levels.map(&.enabled)
    levels = store.line_levels
    select_chunk = ->(c0 : Int32, c1 : Int32) do
      if literal
        store.index.scan_range(regex_text, c0, c1)
               .select { |i| mask.unsafe_fetch(levels.unsafe_fetch(i)) }
      elsif (m = re)
        found = [] of Int32
        c0.upto(c1 - 1) do |i|
          next unless mask.unsafe_fetch(levels.unsafe_fetch(i))
          found << i if m.matches?(store.line(i))
        end
        found
      else # levels only — no text filter at all
        found = [] of Int32
        c0.upto(c1 - 1) do |i|
          found << i if mask.unsafe_fetch(levels.unsafe_fetch(i))
        end
        found
      end
    end

    t0 = Time.instant
    {% if flag?(:execution_context) %}
      parallel_filter(store, select_chunk, gen, t0)
    {% else %}
      sequential_filter(store, select_chunk, gen, t0)
    {% end %}
  end

  # The PARALLEL MAP: one line range per worker on the pool, ordered
  # merge through a channel buffered to the chunk count (workers
  # never block); the collector runs in the default context
  # (parallelism 1 — it can never execute beside the UI fiber, so
  # publishing needs no lock). Superseded jobs drop their result.
  {% if flag?(:execution_context) %}
    def parallel_filter(store : LogStore,
                        select_chunk : (Int32, Int32) -> Array(Int32),
                        gen : Int32, t0 : Time::Instant) : Nil
      pool = @pool ||= Fiber::ExecutionContext::Parallel.new("logs_filter", WORKERS)
      ranges = store.index.chunks(WORKERS)
      ch = Channel(Tuple(Int32, Array(Int32))).new(ranges.size)
      ranges.each_with_index do |(c0, c1), k|
        pool.spawn(name: "logs/#{k}") do
          next if @gen.get != gen
          batch = select_chunk.call(c0, c1)
          ch.send({k, batch}) if @gen.get == gen
        end
      end
      spawn do # collector: ordered merge, publish once
        slots = Array(Array(Int32)?).new(ranges.size, nil)
        ranges.size.times do
          k, batch = ch.receive
          slots[k] = batch
        end
        next unless @gen.get == gen
        merged = Array(Int32).new(store.total // 4 + 16)
        slots.each { |b| merged.concat(b.not_nil!) }
        @rows = merged
        @filtering = false
        @filter_ms = (Time.instant - t0).total_milliseconds
        ctx.request_repaint
      end
    end
  {% end %}

  # Sequential fallback: one cooperative chunk per few ms, partial
  # results streaming in — same ring semantics at the chunk boundary.
  {% unless flag?(:execution_context) %}
    def sequential_filter(store : LogStore,
                          select_chunk : (Int32, Int32) -> Array(Int32),
                          gen : Int32, t0 : Time::Instant) : Nil
      spawn do
        c = 0
        total = store.total
        while c < total
          break if @gen.get != gen
          last = {c + CHUNK, total}.min
          @rows.concat(select_chunk.call(c, last))
          c = last
          @filter_ms = (Time.instant - t0).total_milliseconds
          ctx.request_repaint
          sleep 1.millisecond
        end
        if @gen.get == gen
          @filtering = false
          @filter_ms = (Time.instant - t0).total_milliseconds
          ctx.request_repaint
        end
      end
    end
  {% end %}

  # --- rendering ------------------------------------------------------------

  # The level chips: colored pill, ON = solid fill + dark label,
  # OFF = tinted fill + colored label, count badge included.
  private def render_level_chips(ui : Egui::Ui) : Nil
    ui.horizontal(wrap: false) do |row|
      fs = row.style.font_size
      h = fs * 1.9
      @settings.levels.each_with_index do |lv, i|
        count = @store.try { |s| s.counts.unsafe_fetch(i + 1) } || 0
        label = count > 0 ? "#{lv.name} #{self.class.fmt_compact(count)}" : lv.name
        m = row.fonts.measure(label, fs)
        w = m.x + 20.0
        rect = row.allocate_space(Egui::Vec2.new(w, h))
        col = @colors.unsafe_fetch(i)
        resp = row.interact(rect, Egui::Id.from("logs_viewer/chip/#{lv.name}"),
          Egui::Sense::Click)
        painter = row.painter
        painter.clip = row.clip
        if lv.enabled
          painter.rect(rect, 6.0, gradient: col.on_grad)
          # painter.text anchors y at the text's CENTER (the backend
          # derives the baseline) — rect.center.y lands it dead center.
          painter.text(Egui::Pos2.new(rect.center.x - m.x / 2.0,
            rect.center.y), label, fs, LevelColors::WHITE, bold: true)
        else
          painter.rect(rect, 6.0, gradient: col.off_grad,
            stroke_color: col.off_stroke, stroke_width: 1.0)
          painter.text(Egui::Pos2.new(rect.center.x - m.x / 2.0,
            rect.center.y), label, fs, LevelColors::WHITE)
        end
        toggle_level(i) if resp.clicked?
      end
    end
  end

  # The visible band over the filtered rows — same O(visible)
  # geometry as search1m: fixed row pitch, two bulk skips, one rich
  # label per visible row colored by its level.
  private def render_list(ui : Egui::Ui) : Nil
    t0 = Time.instant
    store = @store
    rows = @rows
    n = store ? rows.size : 0
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
        idx = rows.unsafe_fetch(row)
        text = "##{idx + 1}  #{store.not_nil!.line(idx)}"
        if store && (lid = store.level_of(idx)) > 0 &&
           (c = @colors[lid - 1]?)
          scroll.rich(Egui::RichText.new(text).color(c.text_dim),
            wrap: false, userselect: false)
        else
          scroll.label(text, wrap: false, userselect: false)
        end
        row += 1
      end

      if row < n
        scroll.allocate_space(
          Egui::Vec2.new(0.0, {(n - row) * pitch - gap, 0.0}.max))
      end
    end
    @list_ms = (Time.instant - t0).total_milliseconds
  end

  # --- the frame -------------------------------------------------------------

  # File → Open… (the menu hint says Ctrl+O — the binding makes it true)
  ACTION_OPEN = Egui::HotkeyAction.new("logs_viewer.open")
  @hotkeys_ready = false

  def update(ctx : Egui::Context) : Nil
    # Per-frame theme set (the notepad pattern): the driver touches
    # style state on DPI/focus events after the constructor — a
    # set-once theme can end up half-applied (menu popups kept stale
    # colors). Cheap to redo every frame.
    ctx.theme = Egui::Theme.dark
    @exml.reload_if_changed
    unless @hotkeys_ready
      ctx.hotkeys.bind("Ctrl+O", ACTION_OPEN)
      @hotkeys_ready = true
    end
    open_dialog if ctx.consume_action(ACTION_OPEN)
    ctx.request_repaint if @rt.bool("continuous") && !ENV["NOREPAINT"]?
    sync_store(ctx)
    @renderer.render_routes(ctx, @exml, @rt)
    # Menu diagnostics (LV_DEBUG=1): live-only popup issues print
    # their per-frame state here — headless specs show the popup
    # renders fine, so a live-only breakage shows up in this trace.
    if ENV["LV_DEBUG"]? && (mo = ctx.memory.menu_open)
      STDERR.printf("[lv] mo=%s pops=%d\n", mo.inspect,
        ctx.memory.open_popups.size)
    end
  end

  private def sync_store(ctx : Egui::Context) : Nil
    s = @rt.strings
    b = @rt.bools
    b["show_bench"] = @settings.bench?
    s["bench_mark"] = @settings.bench? ? "✓ " : ""
    if (store = @store) && (path = store.path)
      s["file_label"] = "#{File.basename(path)} · #{self.class.fmt(store.total)} lines"
    elsif (store = @store)
      s["file_label"] = "demo log · #{self.class.fmt(store.total)} lines"
    end
    mode = {% if flag?(:execution_context) %} "parallel ×#{WORKERS}" {% else %} "sequential" {% end %}
    s["stats"] = "shown: #{self.class.fmt(@rows.size)}" \
                 " · filter: #{"%.1f" % @filter_ms} ms (#{mode})" \
                 " · list: #{"%.2f" % @list_ms} ms" \
                 "#{@filtering ? " · filtering…" : ""}"
    status = @load_status.dup
    if (err = @regex_error)
      status += "  ⚠ regex: #{err}"
    end
    s["status"] = status
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

  def self.fmt_compact(n : Int) : String
    return n.to_s if n < 1000
    return "#{(n / 1000).round(1)}k" if n < 1_000_000
    "#{(n / 1_000_000).round(1)}M"
  end
end

# The framework CLI pulls --page out of ARGV in place; the rest are
# file paths (notepad's convention) — the first one opens at boot.
{% unless env("EGUI_EMBEDDED") %}
files = Egui::CLI.parse(ARGV)[:argv].dup.reject(&.starts_with?("--"))
app = LogsViewerApp.new(files)
Egui.run(app, title: "LogsViewer — #{DEMO_N >= 1_000_000 ? "demo " : ""}log",
  width: 1060, height: 680, vsync: ENV["EGUI_VSYNC"]? == "1",
  inspector: :hidden)
{% end %}
