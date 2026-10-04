# System monitor demo — GNOME System Monitor-style live scrolling
# graphs: one per CPU core, RAM, and network (receiving/sending).
#
# Data source: sysinfo.cr (https://github.com/OrelSokolov/sysinfo.cr),
# a DEVELOPMENT dependency of egui-cr: demos may require it, the
# framework itself never does (see shard.yml). RAM, per-core busy% and
# network rates all come from there, so the demo is cross-platform
# (Linux / macOS / Windows); on other platforms the graphs stay flat
# at zero.
#
# The graphs scroll CONTINUOUSLY (each sample is tagged with its
# monotonic timestamp and x = right edge - age, so the curve slides
# every frame, not once per sample) with an EKG-style time grid.

require "../src/egui"
require "../src/egui/backend/sokol"
require "sysinfo"

module SysMon
  # Counter snapshot cadence — the GNOME System Monitor default.
  SAMPLE_INTERVAL = 1.0
  # Seconds of history visible across a graph's full width.
  WINDOW = 60.0
  # Vertical time gridlines every N seconds (scroll with the data).
  GRID_STEP = 5.0
  # Core graph grid: N small graphs per row.
  CORE_COLS = 4

  # Light palette (GNOME System Monitor on a light theme; the app
  # theme itself is switched to Theme.light in the app's initialize).
  BG        = Egui::Color32.rgb(0xfa, 0xfa, 0xf7)
  FRAME     = Egui::Color32.rgba(0, 0, 0, 36)
  H_GRID    = Egui::Color32.rgba(0, 0, 0, 22)
  V_GRID    = Egui::Color32.rgba(0, 0, 0, 12)
  RAM_COLOR = Egui::Color32.rgb(0x26, 0xa2, 0x69) # GNOME green
  RX_COLOR  = Egui::Color32.rgb(0x1c, 0x5f, 0xbf) # GNOME blue
  TX_COLOR  = Egui::Color32.rgb(0xc6, 0x46, 0x00) # GNOME dark orange

  # Per-core curve colors: hue stepped by the golden-ratio conjugate
  # (0.618…) — consecutive hues are maximally apart and the sequence
  # never repeats (irrational step), so 128+ cores get 128+ DISTINCT
  # colors. Slightly desaturated/darkened to read on white.
  def self.core_color(i : Int32) : Egui::Color32
    h = (i * 0.6180339887498949) % 1.0
    Egui::Hsva.new(h, 0.55, 0.72, 1.0).to_color
  end

  # "1.4 MiB/s" / "523 KiB/s" / "87 B/s".
  def self.human_rate(bytes_per_s : Float64) : String
    return "#{"%.0f" % bytes_per_s} B/s" if bytes_per_s < 1024
    k = bytes_per_s / 1024
    return "#{"%.1f" % k} KiB/s" if k < 1024
    "#{"%.1f" % (k / 1024)} MiB/s"
  end

  # A ring of timestamped samples (monotonic seconds, value).
  class Series
    getter pts = Deque({Float64, Float64}).new

    def push(t : Float64, v : Float64) : Nil
      @pts << {t, v}
      t0 = t - WINDOW - SAMPLE_INTERVAL * 2.0
      while (first = @pts.first?) && first[0] < t0
        @pts.shift
      end
    end

    def last_value : Float64
      @pts.last?.try(&.[1]) || 0.0
    end

    # Peak since `t0` (autoscaling the network axis).
    def max_since(t0 : Float64) : Float64
      m = 0.0
      @pts.each { |t, v| m = v if t >= t0 && v > m }
      m
    end
  end

  # One scrolling graph: `series` (value, color) pairs overlaid on a
  # shared 0..y_max axis. Drawn straight onto the painter after the
  # caller allocated `rect` — no widget, immediate mode all the way.
  def self.graph(painter : Egui::Painter, rect : Egui::Rect,
                 series : Array({Series, Egui::Color32}),
                 now : Float64, y_max : Float64) : Nil
    # Degenerate rect (a 0-width column on a resize/layout frame): a
    # px-per-second of 0 would turn any x/pps loop below into an
    # infinite one — bail instead of drawing nothing meaningful.
    return if rect.width < 1.0 || rect.height < 1.0

    painter.rect(rect, 3.0, BG, FRAME, 1.0)

    w = rect.width
    h = rect.height
    pps = w / WINDOW # px per second
    y = ->(v : Float64) do
      (rect.max.y - (v.clamp(0.0, y_max) / y_max) * h).to_f64
    end

    # Horizontal gridlines at 1/4..3/4 (the 0 and 1 lines are the
    # frame itself), EKG-style vertical lines scrolling with the data.
    1.upto(3) do |i|
      gy = rect.min.y + h * i / 4.0
      painter.line(Egui::Pos2.new(rect.min.x, gy),
        Egui::Pos2.new(rect.max.x, gy), 1.0, H_GRID)
    end
    # Verticals sit at whole multiples of GRID_STEP seconds of AGE, so
    # they slide at the same speed as the samples. Iterated over a
    # bounded integer range, never a float condition — the line count
    # is WINDOW/GRID_STEP + 1 by construction.
    k0 = ((now - WINDOW) / GRID_STEP).ceil.to_i
    k1 = (now / GRID_STEP).floor.to_i
    (k0..k1).each do |k|
      x = rect.max.x - (now - k * GRID_STEP) * pps
      next if x < rect.min.x || x > rect.max.x
      painter.line(Egui::Pos2.new(x, rect.min.y),
        Egui::Pos2.new(x, rect.max.y), 1.0, V_GRID)
    end

    series.each do |s, color|
      # Smooth curve: straight segments through the sample points. A
      # segment between two samples is FIXED once both exist — it only
      # slides left afterwards; a new sample adds a segment at the
      # right edge and never rewrites what is already on screen. (The
      # area fill is gone by design: filled spans re-ramped in place
      # at every sample and twitched.) The newest value is held to
      # the right edge ("now") until the next sample connects to it.
      prev : Egui::Pos2? = nil
      s.pts.each do |t, v|
        p = Egui::Pos2.new(rect.max.x - (now - t) * pps, y.call(v))
        if first = prev
          painter.line(first, p, 1.6, color)
        end
        prev = p
      end
      if first = prev
        painter.line(first, Egui::Pos2.new(rect.max.x, first.y), 1.6, color)
      end
    end
  end
end

class SystemMonitorApp < Egui::App
  @cpu_series = [] of SysMon::Series
  @ram_series = SysMon::Series.new
  @rx_series = SysMon::Series.new
  @tx_series = SysMon::Series.new
  @last_sample = -1.0e18_f64
  @ram_total_kb : Int64 = 0
  @cores = 0
  # Cores view: false = one small graph per core (default), true = all
  # cores overlaid in a single graph (Settings menu).
  @merged = false

  def initialize
    super
    # Light theme — a system monitor reads better on white (GNOME's
    # default); the graph palette in SysMon matches it. NOTE: bare
    # `theme = …` would be a LOCAL variable in Crystal — the setter
    # needs an explicit receiver.
    self.theme = Egui::Theme.light
    # Baseline CPU sample: sysinfo's percentages read 0 until the
    # second refresh, and the core count is known from the first —
    # seed the series now so the first frame knows the layout; every
    # series fills from the right edge like GSM's do.
    Sysinfo.refresh_cpu
    @cores = Sysinfo.cpu_percentages.size
    @cores.times { @cpu_series << SysMon::Series.new }
  end

  def update(ctx : Egui::Context) : Nil
    # The context's clock (monotonic seconds) — the same timebase the
    # graph x-positions below are derived from.
    now = ctx.input.time

    # Continuous scroll: repaint every frame, resample on the cadence.
    ctx.request_repaint
    if now - @last_sample >= SysMon::SAMPLE_INTERVAL
      @last_sample = now
      sample(now)
    end

    ctx.routes do |r|
      r.page "root/root" do
        # Settings menu: the cores view mode (all cores overlaid in
        # one graph vs one graph per core). The check rides the active
        # row, notepad-style.
        ctx.menu_bar do |bar|
          bar.menu_button("Settings") do |menu|
            menu.menu_item("Merged cores", icon: @merged ? :check : nil) do
              @merged = true
            end
            menu.menu_item("Separate cores", icon: @merged ? nil : :check) do
              @merged = false
            end
          end
        end

        ctx.central_panel do |ui|
          Egui::ScrollArea.new.show(ui) do |inner|
            cpu_section(inner, now)
            ram_section(inner, now)
            net_section(inner, now)
          end
        end
      end
    end
  end

  private def sample(now : Float64) : Nil
    Sysinfo.refresh_cpu
    core_pcts = Sysinfo.cpu_percentages
    @cores = core_pcts.size
    if @cpu_series.size != core_pcts.size
      @cpu_series = core_pcts.map { SysMon::Series.new }
    end
    core_pcts.each_with_index { |pct, i| @cpu_series[i].push(now, pct.to_f64) }

    if mem = Sysinfo.memory
      @ram_total_kb = mem.total_kb
      @ram_series.push(now, mem.used_kb.to_f64)
    end

    Sysinfo.refresh_network
    if net = Sysinfo.network
      # sysinfo reports KB/s; the graph and human_rate work in B/s.
      @rx_series.push(now, net.received_kb_s.to_f64 * 1024.0)
      @tx_series.push(now, net.sent_kb_s.to_f64 * 1024.0)
    end
  end

  private def cpu_section(ui : Egui::Ui, now : Float64) : Nil
    ui.heading("CPU")
    total = @cpu_series.empty? ? 0.0 : @cpu_series.sum(&.last_value) / @cpu_series.size
    ui.label("Total #{"%.1f" % total}%  ·  #{@cores} cores")

    if @merged
      # All cores overlaid in one shared 0-100% graph (GSM's combined
      # view): one line per core, colors from the golden-ratio cycle.
      all = @cpu_series.map_with_index { |s, i| {s, SysMon.core_color(i)} }
      rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, 160.0))
      SysMon.graph(ui.painter, rect, all, now, 100.0)
      return
    end

    @cpu_series.each_slice(SysMon::CORE_COLS).with_index do |row, row_i|
      ui.columns(SysMon::CORE_COLS) do |cols|
        row.each_with_index do |series, i|
          col = cols[i]
          core = row_i * SysMon::CORE_COLS + i
          pct = series.last_value
          col.label("CPU #{core + 1}  #{"%.0f" % pct}%")
          rect = col.allocate_space(
            Egui::Vec2.new(col.available_width, 64.0))
          SysMon.graph(col.painter, rect,
            [{series, SysMon.core_color(core)}], now, 100.0)
        end
        # Fill the row's empty cells so the grid stays rectangular
        # (23 cores → 6 rows, the last one half empty).
        (row.size...cols.size).each do |i|
          cols[i].allocate_space(
            Egui::Vec2.new(cols[i].available_width, 84.0))
        end
      end
    end
  end

  private def ram_section(ui : Egui::Ui, now : Float64) : Nil
    ui.heading("Memory")
    used_gib = @ram_series.last_value / 1024.0 / 1024.0
    total_gib = @ram_total_kb.to_f64 / 1024.0 / 1024.0
    pct = total_gib > 0 ? used_gib / total_gib * 100.0 : 0.0
    ui.label("#{"%.1f" % used_gib} GiB of #{"%.1f" % total_gib} GiB  ·  #{"%.1f" % pct}%")
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, 110.0))
    SysMon.graph(ui.painter, rect, [{@ram_series, SysMon::RAM_COLOR}],
      now, {@ram_total_kb.to_f64, 1.0}.max)
  end

  private def net_section(ui : Egui::Ui, now : Float64) : Nil
    ui.heading("Network")
    rx = @rx_series.last_value
    tx = @tx_series.last_value
    ui.label("Receiving #{SysMon.human_rate(rx)}   ·   Sending #{SysMon.human_rate(tx)}")
    rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, 110.0))
    # Autoscale to the window peak (×1.25 headroom, ≥4 KiB/s) like GSM.
    peak = {@rx_series.max_since(now - SysMon::WINDOW),
            @tx_series.max_since(now - SysMon::WINDOW)}.max * 1.25
    y_max = {peak, 4096.0}.max
    SysMon.graph(ui.painter, rect,
      [{@rx_series, SysMon::RX_COLOR}, {@tx_series, SysMon::TX_COLOR}],
      now, y_max)
  end
end

# Headless drivers (debug scripts) set EGUI_NOWINDOW=1 before
# requiring this file to reuse the app class without opening a sokol
# window.
unless ENV["EGUI_NOWINDOW"]?
  Egui::Backend::Sokol.run(SystemMonitorApp.new,
    title: "egui-cr — system monitor",
    inspector: :hidden)
end
