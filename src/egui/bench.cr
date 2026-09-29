# Headless frame benchmark — an EXTERNAL orchestrator around any
# Egui::App (the "profile first, optimize second" tool):
#
#   Bench.run(app, width: 1920, height: 1080) do |frame|
#     frame.mouse_move(960, 540)      # synthetic input into RawInput
#   end
#
# The frame pipeline minus the backend is pure Crystal —
# `begin_frame → app.update → end_frame → Array(PaintCmd)` — so the
# bench drives it without a window and measures exactly the part of a
# frame the CPU owns BEFORE any FFI/GPU work: phase timings per frame
# (begin/update/end), the paint-command mix per frame (the input the
# backend will be asked to emit), and named `span`s around the
# framework's known-hot inner paths (widget `#ui`, Svg#paint, font
# measure/layout, …).
#
# Two design constraints shape the data model:
#
#   * A FEW frames, not hundreds — the bench exists to answer "where
#     does one frame in THIS app state spend its time", so a scenario
#     navigates the app into the interesting state and runs a handful
#     of measured frames after a warmup (caches hot).
#   * AGGREGATED spans, not raw traces — spans accumulate into
#     {name → calls, self, inclusive} over all frames, so the report
#     is kilobytes whatever the widget count. Self time is inclusive
#     minus the time of nested spans (Button self excludes the Svg it
#     painted), computed with a span stack like every flamegraph
#     profiler does.
#
# Spans/counters are collected only while a bench runs
# (`Bench.collecting?`); the guard is a single class-var read and the
# `yield` is inlined, so the hooks cost nothing in normal app frames.

module Egui
  module Bench
    # -- span / counter collection ------------------------------------------

    # Aggregated numbers for one span name (or widget class).
    class Agg
      property calls : Int32 = 0
      property self_ns : Int64 = 0_i64   # exclusive of nested spans
      property incl_ns : Int64 = 0_i64   # wall time inside, nested included

      def self_per_call_ns : Float64
        @calls.zero? ? 0.0 : @self_ns.to_f64 / @calls
      end
    end

    # One live span on the stack; accumulates the inclusive time of
    # spans nested inside it (for the self-time subtraction).
    private class OpenSpan
      property children_ns : Int64 = 0_i64
    end

    @@collecting = false
    @@aggregates = {} of String => Agg
    @@counters = {} of String => Int32
    @@stack = [] of OpenSpan

    def self.collecting? : Bool
      @@collecting
    end

    # Time the block under `name` while a bench runs; passes the
    # block's value through (the guard may wrap value-producing calls,
    # e.g. Context#end_frame's command flatten). Overhead when not
    # collecting: one class-var read + an inlined yield.
    def self.span(name : String, &)
      return yield unless @@collecting
      open = OpenSpan.new
      @@stack << open
      t0 = Time.instant
      begin
        result = yield
        result
      ensure
        incl = (Time.instant - t0).total_nanoseconds.to_i64
        @@stack.pop
        if parent = @@stack.last?
          parent.children_ns += incl
        end
        agg = (@@aggregates[name] ||= Agg.new)
        agg.calls += 1
        agg.incl_ns += incl
        agg.self_ns += incl - open.children_ns
      end
    end

    # Free-form monotonic counter ("fonts.layout.hit" etc.) — volume
    # facts that explain the span numbers.
    def self.count(key : String) : Nil
      @@counters[key] = (@@counters[key]? || 0) + 1
    end

    def self.counters : Hash(String, Int32)
      @@counters
    end

    def self.aggregates : Hash(String, Agg)
      @@aggregates
    end

    def self.reset : Nil
      @@aggregates.clear
      @@counters.clear
      @@stack.clear
    end

    # -- the orchestrator ----------------------------------------------------

    # Exercises the Svg raster-texture path headless: same dummy ids as
    # DummyTextureRegistry, but `graphical?` — so Svg#paint bakes its
    # raster cache (real CPU cost) and emits ImageCmd instead of
    # stroking vectors, matching what the sokol backend does per frame.
    class GraphicalTextureRegistry < DummyTextureRegistry
      def graphical? : Bool
        true
      end
    end

    # Per-frame handle the scenario block drives: inject input events,
    # poke app state, navigate — this is how the bench walks the app
    # into the state worth measuring.
    class FrameDriver
      getter index : Int32
      getter app : Egui::App
      property events : Array(Egui::Event)

      def initialize(@app : Egui::App, @index : Int32,
                     @events : Array(Egui::Event))
      end

      def ctx : Context
        @app.ctx
      end

      def mouse_move(x : Float64, y : Float64) : Nil
        @events << Egui::Event.pointer_moved(Egui::Pos2.new(x, y))
      end

      def scroll(x : Float64, y : Float64) : Nil
        @events << Egui::Event.scroll(Egui::Vec2.new(x, y))
      end
    end

    # One measured frame: the three pipeline phases plus the command
    # mix end_frame produced (what a backend would be asked to emit).
    class FrameStats
      property begin_ns : Int64 = 0_i64
      property update_ns : Int64 = 0_i64
      property end_ns : Int64 = 0_i64
      property commands = {} of String => Int32

      def total_ns : Int64
        @begin_ns + @update_ns + @end_ns
      end
    end

    # Drive `app` headless: `warmup` frames (caches fill — Svg bakes,
    # glyph atlas fills), then `frames` measured ones, running
    # `scenario` before each frame so it can move the app into the
    # state under test (mouse moves, router navigation, direct state
    # pokes through `driver.app`). With `mouse: true` (default) each
    # frame also gets a pointer move at the screen center — the
    # "idle but the cursor moves" worst case for repaint-heavy apps.
    #
    # The app's Context is prepared for realistic headless measuring:
    # the font backend the caller installed stays (put a real one there
    # for realistic measure() costs), and the texture registry becomes
    # a graphical dummy so Svg icons take their production code path.
    # pixels_per_point stays whatever the ctx has (1.0 unless set).
    #
    # Blockless convenience overload: the default injected mouse move
    # (the "cursor moves, nothing else happens" scenario) is all the
    # frame needs.
    def self.run(app : Egui::App, width : Float64 = 1920.0,
                 height : Float64 = 1080.0, warmup : Int32 = 5,
                 frames : Int32 = 20, mouse : Bool = true,
                 print : Bool = true) : Report
      run(app, width: width, height: height, warmup: warmup, frames: frames,
        mouse: mouse, print: print) { |_driver| }
    end

    # Returns the Report (also printed to STDOUT unless `print: false`).
    def self.run(app : Egui::App, width : Float64 = 1920.0,
                 height : Float64 = 1080.0, warmup : Int32 = 5,
                 frames : Int32 = 20, mouse : Bool = true,
                 print : Bool = true, &scenario : FrameDriver ->) : Report
      screen = Rect.from_min_size(Pos2.zero, Vec2.new(width, height))
      # The Svg raster cache (and any texture user) must see a
      # graphical registry, or icons degrade to the vector path and
      # the bench measures a different program than the one shipping.
      app.ctx.textures = GraphicalTextureRegistry.new

      stats = [] of FrameStats
      reset
      @@collecting = true
      time = 0.0
      events = [] of Egui::Event
      begin
        (warmup + frames).times do |i|
          events.clear
          driver = FrameDriver.new(app, i, events)
          scenario.call(driver)
          if mouse && events.empty?
            driver.mouse_move(width / 2.0, height / 2.0)
          end
          time += 1.0 / 60.0 # a steady 60Hz dt like the real loop
          raw = RawInput.new(screen, events.dup, time)

          fs = FrameStats.new
          t0 = Time.instant
          app.ctx.begin_frame(raw)
          fs.begin_ns = elapsed(t0)
          t1 = Time.instant
          app.update(app.ctx)
          fs.update_ns = elapsed(t1)
          t2 = Time.instant
          commands = app.ctx.end_frame
          fs.end_ns = elapsed(t2)
          count_commands(commands, fs.commands)
          stats << fs if i >= warmup
        end
      ensure
        @@collecting = false
      end

      report = Report.new(app.class.name, width, height, warmup, frames,
        stats, aggregates.dup, counters.dup)
      puts report if print
      report
    end

    private def self.elapsed(t0) : Int64
      (Time.instant - t0).total_nanoseconds.to_i64
    end

    # Classify the frame's paint commands. Rounded rects and text
    # expand at EMIT time (a rounded fill is a ~24-quad perimeter fan,
    # text is one quad per glyph), so the mix predicts the backend's
    # per-command FFI load — the one cost a headless bench cannot run.
    private def self.count_commands(commands : Array(PaintCmd),
                                    into : Hash(String, Int32)) : Nil
      bump = ->(k : String) { into[k] = (into[k]? || 0) + 1 }
      glyphs = 0
      commands.each do |cmd|
        case cmd
        when RectCmd
          if cmd.rounding > 0.5
            bump.call("rect(rounded)")
          else
            bump.call("rect")
          end
        when TextCmd
          bump.call("text")
          glyphs += cmd.text.size
        when ImageCmd    then bump.call("image")
        when LineCmd     then bump.call("line")
        when CircleCmd   then bump.call("circle")
        when ArcCmd      then bump.call("arc")
        when ShadowCmd   then bump.call("shadow")
        end
      end
      into["text-glyphs"] = glyphs
    end

    # -- the report -----------------------------------------------------------

    # Aggregated result of one Bench.run: per-frame phase percentiles,
    # mean command mix, span table (self/inclusive per name) and the
    # framework counters. `#to_s` renders the human-readable form.
    class Report
      getter app_name : String
      getter width : Float64
      getter height : Float64
      getter warmup : Int32
      getter frames : Int32
      getter frame_stats : Array(FrameStats)
      getter aggregates : Hash(String, Agg)
      getter counters : Hash(String, Int32)

      def initialize(@app_name, @width, @height, @warmup, @frames,
                     @frame_stats, @aggregates, @counters)
      end

      def to_s(io : IO) : Nil
        io << "== egui.cr bench — " << @app_name << "\n"
        io << "   screen " << @width.to_i << "×" << @height.to_i
        io << " · warmup " << @warmup << " · frames " << @frames << "\n"
        io << "   (central_panel is deferred: its content renders inside"
        io << " end_frame — see the span table)\n\n"

        io << "phases (ms)            p50     mean     p95     max\n"
        data = { {"begin_frame",    ->(fs : FrameStats) { fs.begin_ns }},
                 {"update",         ->(fs : FrameStats) { fs.update_ns }},
                 {"end_frame",      ->(fs : FrameStats) { fs.end_ns }},
                 {"frame(pre-FFI)", ->(fs : FrameStats) { fs.total_ns }} }
        total_p50 = 0.0
        data.each do |name, key|
          vals = @frame_stats.map { |fs| key.call(fs) }
          p50, mean, p95, max = percentiles(vals)
          total_p50 = p50 if name == "frame(pre-FFI)"
          io << "  " << name.ljust(17)
          io << ms(p50) << ms(mean) << ms(p95) << ms(max) << "\n"
        end
        io << "  → " << (total_p50 / 1_000_000.0).round(2)
        io << " ms/frame ≈ " << (1_000_000_000.0 / total_p50).round.to_i
        io << " fps CPU ceiling (before backend emission)\n\n"

        io << "commands/frame (mean): "
        if @frame_stats.empty?
          io << "—\n\n"
        else
          mix = {} of String => Int32
          @frame_stats.each do |fs|
            fs.commands.each { |k, v| mix[k] = (mix[k]? || 0) + v }
          end
          mix.each { |k, v| mix[k] = (v.to_f64 / @frame_stats.size).round.to_i }
          io << mix.map { |k, v| "#{k} #{v}" }.join(" · ") << "\n\n"
        end

        io << "spans by self time (warmup + measured frames — one-time"
        io << " costs like Svg bakes live in the warmup half):\n"
        io << "  name                               calls"
        io << "    self ms   self µs/call     incl ms\n"
        aggs = @aggregates.to_a.sort_by! { |_, a| -a.self_ns }
        aggs.first(25).each do |name, a|
          label = name.size > 34 ? name[0, 31] + "…" : name
          io << "  " << label.ljust(35)
          io << a.calls.to_s.ljust(9)
          io << ms(a.self_ns)
          io << us(a.self_per_call_ns)
          io << ms(a.incl_ns) << "\n"
        end
        io << "\n"

        io << "counters:\n"
        @counters.to_a.sort_by! { |k, _| k }.each do |k, v|
          io << "  " << k.ljust(36) << v << "\n"
        end
      end

      # Fixed-width ms/µs columns (sprintf, not Float#format — its
      # argument is not a printf string).
      private def ms(ns) : String
        "%9.2f" % (ns.to_f64 / 1_000_000.0)
      end

      private def us(ns) : String
        "%13.1f" % (ns.to_f64 / 1_000.0)
      end

      private def percentiles(vals : Array(Int64)) : {Float64, Float64, Float64, Float64}
        return {0.0, 0.0, 0.0, 0.0} if vals.empty?
        s = vals.sort
        at = ->(q : Float64) do
          idx = (q * (s.size - 1)).floor.to_i.clamp(0, s.size - 1)
          s[idx].to_f64
        end
        mean = s.sum.to_f64 / s.size
        {at.call(0.5), mean, at.call(0.95), s.last.to_f64}
      end
    end
  end
end
