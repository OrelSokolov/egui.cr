# Scroll-oracle recorder (driver side): captures the raw wheel stream
# (timestamp, deltas, precise/momentum/phase bits) and caller-provided
# offset samples into an in-memory buffer, then writes them as JSON for
# the compare tool (scripts/compare_scroll.py). Format matches the
# native NSScrollView oracle (examples/native_scroll.m), so the two
# timelines overlay on the same charts.
#
# Buttons (Record/Stop/Save) live in the app (examples/egui_scroll.cr);
# they call start/stop/save here. `start` strips the buffer first:
# everything before the last >=1 s idle gap is dropped, so pre-record
# idle history never pollutes the capture.
require "json"

module Egui
  module ScrollRecorder
    struct ScrollEvent
      getter t, sy, sx, precise, momentum, gesture, inj
      def initialize(@t : Float64, @sy : Float64, @sx : Float64,
                     @precise : Bool, @momentum : Bool, @gesture : Bool,
                     @inj : Bool = false)
      end
    end

    struct OffsetSample
      getter t, y, sy, active, diag
      def initialize(@t : Float64, @y : Float64, @sy : Float64 = 0.0,
                     @active : Bool = true, @diag : String = "")
      end
    end

    # One scheduled event of a loaded foreign recording (native oracle
    # JSON): t is relative to the recording's first event, so the pump
    # re-bases it onto the replay clock.
    struct ScheduledEvent
      getter t, sy, sx, precise
      def initialize(@t : Float64, @sy : Float64, @sx : Float64,
                     @precise : Bool)
      end
    end

    @@t0 : Time::Instant = Time.instant
    @@events = [] of ScrollEvent
    @@offsets = [] of OffsetSample
    @@recording = false
    @@replay = [] of ScheduledEvent
    @@replay_i = 0
    @@replay_t0 = 0.0
    @@replaying = false
    @@native_start_offset = 0.0

    # Monotonic seconds since the recorder's epoch — the single clock
    # for both event and offset entries.
    def self.now : Float64
      (Time.instant - @@t0).total_seconds
    end

    def self.recording? : Bool
      @@recording
    end

    def self.events : Array(ScrollEvent)
      @@events
    end

    def self.offsets : Array(OffsetSample)
      @@offsets
    end

    # Strip: drop everything before the last >=1 s idle gap (same rule
    # as the native oracle), then start recording.
    def self.start : Nil
      strip
      @@recording = true
    end

    def self.stop : Nil
      @@recording = false
    end

    # Called from the driver's wheel branch. Live input outside an
    # active recording is ignored — post-replay touches must not leak
    # into the buffer (the strip pass only trims the PRE-record tail).
    def self.record_event(sy : Float64, sx : Float64, precise : Bool,
                          momentum : Bool, gesture : Bool,
                          injected : Bool = false) : Nil
      return unless @@recording
      @@events << ScrollEvent.new(now, sy, sx, precise, momentum, gesture,
        injected)
    end

    # Called from the app once per frame while recording. `sy` is the
    # frame's raw input.scroll.y — with it the JSON shows whether a
    # frozen offset had deltas on hand (consumption bug) or none
    # (delivery bug). `active` mirrors the sink arbitration verdict
    # (memory.active_scroll_area? == area id) the frame saw.
    def self.record_offset(y : Float64, sy : Float64 = 0.0,
                           active : Bool = true, diag : String = "") : Nil
      @@offsets << OffsetSample.new(now, y, sy, active, diag) if @@recording
    end

    private def self.strip : Nil
      times = [] of Float64
      @@events.each { |e| times << e.t }
      @@offsets.each { |o| times << o.t }
      times.sort!
      return if times.size < 2
      cut = -1.0
      times.each_cons(2) { |pair| cut = pair[0] if pair[1] - pair[0] >= 1.0 }
      return if cut < 0.0
      @@events.reject! { |e| e.t <= cut }
      @@offsets.reject! { |o| o.t <= cut }
    end

    def self.save(path : String) : Nil
      File.open(path, "w") do |f|
        JSON.build(f) do |json|
          json.object do
            json.field("app", "egui")
            json.field("t0", Time.utc.to_unix_f)
            json.field("recording", @@recording)
            json.field("events") do
              json.array do
                @@events.each do |e|
                  json.object do
                    json.field("t", e.t)
                    json.field("sy", e.sy)
                    json.field("sx", e.sx)
                    json.field("precise", e.precise ? 1 : 0)
                    json.field("phase", e.gesture ? 1 : 0)
                    json.field("momentum", e.momentum ? 1 : 0)
                    json.field("inj", e.inj ? 1 : 0)
                  end
                end
              end
            end
            json.field("offsets") do
              json.array do
                @@offsets.each do |o|
                  json.object do
                    json.field("t", o.t)
                    json.field("y", o.y)
                    json.field("sy", o.sy)
                    json.field("active", o.active ? 1 : 0)
                    json.field("diag", o.diag) unless o.diag.empty?
                  end
                end
              end
            end
          end
        end
      end
    end

    # --- foreign-recording replay -------------------------------------
    # The native oracle's JSON loads here; start_replay schedules its
    # events onto this process's clock and the driver's A-loop pumps
    # them into the same event bus real touchpad input uses. The egui
    # offset response is then recorded against the IDENTICAL event
    # sequence the native app ran — overlay the two offset curves and
    # the divergence is pure pipeline behavior.

    def self.load(path : String) : Int32
      data = JSON.parse(File.read(path))
      raw = data["events"].as_a
      base = raw.empty? ? 0.0 : raw[0]["t"].as_f
      @@replay = raw.map do |e|
        ScheduledEvent.new(e["t"].as_f - base, e["sy"].as_f, e["sx"].as_f,
          e["precise"].as_i != 0)
      end
      # The native capture's starting offset — the replay must begin
      # from the SAME scroll position, or edge-clamped phases of the
      # gesture (e.g. an up-leg recorded from mid-gesture) diverge
      # against a view parked elsewhere.
      @@native_start_offset = data["offsets"].as_a.first?.try(&.["y"].as_f) || 0.0
      @@replay_i = 0
      @@replay.size
    rescue ex
      STDERR.puts "[replay] load failed: #{ex.message}"
      0
    end

    # The loaded native recording's starting scroll offset (px) — the
    # app applies it before starting the replay.
    def self.native_start_offset : Float64
      @@native_start_offset
    end

    def self.replaying? : Bool
      @@replaying
    end

    # Progress for the UI: events already pumped / total.
    def self.replay_pos : {Int32, Int32}
      {@@replay_i, @@replay.size}
    end

    # Seconds until the next scheduled event fires (0.0 when overdue),
    # nil when no replay is running — the A-loop caps its pipe wait by
    # this so an idle worker still wakes exactly on the schedule.
    def self.replay_next_in : Float64?
      return nil unless @@replaying && @@replay_i < @@replay.size
      {@@replay_t0 + @@replay[@@replay_i].t - now, 0.0}.max
    end

    # Begin: a FRESH capture (the buffer holds the previous replay's
    # events otherwise — the 110-vs-111 bookkeeping bug), strip, then
    # the schedule re-bases onto now + delay.
    def self.start_replay(delay : Float64 = 0.5) : Nil
      return if @@replay.empty?
      @@events.clear
      @@offsets.clear
      @@recording = true
      @@replay_t0 = now + delay
      @@replay_i = 0
      @@replaying = true
    end

    def self.stop_replay : Nil
      @@replaying = false
    end

    # Called once per A-loop iteration. Returns the events due at this
    # instant as egui Events (the same scroll deltas real input uses —
    # precise flag rides along), and self-terminates at the end of the
    # schedule. Native-oracle deltas are RAW points; sokol's live path
    # hands Crystal ÷10 of those (its "lines" convention), so injection
    # scales by the same factor — replay must enter the pipeline
    # exactly where the touchpad enters it, or the response won't
    # compare.
    def self.replay_due : Array(Egui::Event)
      due = [] of Egui::Event
      return due unless @@replaying
      rel = now - @@replay_t0
      while @@replay_i < @@replay.size && @@replay[@@replay_i].t <= rel
        e = @@replay[@@replay_i]
        due << Egui::Event.scroll(
          Egui::Vec2.new(e.sx * 0.1, -e.sy * 0.1), e.precise)
        @@replay_i += 1
      end
      if @@replay_i >= @@replay.size
        @@replaying = false
        # Schedule exhausted — stop the capture here, not at Save: any
        # live touch after the replay would otherwise pollute the
        # offset recording (277 real events in one session).
        @@recording = false
      end
      due
    end
  end
end
