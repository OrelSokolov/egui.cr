# Scroll-oracle twin for tmp/native_scroll.m: the same striped content
# (200 rows × 28 px, 520×640 window) under a plain ScrollArea, with the
# same Record/Stop/Save capture. Events come from the driver's wheel
# branch (ScrollRecorder.record_event); the real content offset is
# sampled once per frame from the ScrollArea's state cell in Memory —
# the same cell the widget itself scrolls by, so what we log is what
# is on screen. JSON format matches the native oracle; overlay the two
# with scripts/compare_scroll.py.

require "../src/egui/driver_selector"

class EguiScrollApp < Egui::App
  ROWS    = 200
  ROW_H   = 28.0
  AREA_ID = Egui::Id.from("egui_scroll_oracle")
  SAVE_PATH = File.join(__DIR__, "..", "tmp", "scroll_egui.json")
  NATIVE_PATH = File.join(__DIR__, "..", "tmp", "scroll_native.json")

  @load_msg = ""
  AUTO = !!ENV["EGUI_SCROLL_AUTO"]?
  @auto_started = false
  @auto_done_at : Float64? = nil

  def update(ctx : Egui::Context) : Nil
    rec = Egui::ScrollRecorder
    # The replay pump lives in the driver's A-loop, but the loop only
    # produces frames while something keeps asking for them — during a
    # replay run the window must repaint every tick.
    ctx.request_repaint if rec.replaying?
    if AUTO && !@auto_started
      @auto_started = true
      n = rec.load(NATIVE_PATH)
      if n.zero?
        puts "[auto] load FAILED"
        exit(1)
      end
      puts "[auto] loaded #{n} events, replay starts"
      rec.start_replay
      @load_msg = "replaying…"
    elsif AUTO && @auto_started && !rec.replaying?
      # Schedule exhausted (recording self-stopped): settle a moment
      # so the last deltas land in an offset sample, then save+exit.
      done = @auto_done_at || (ctx.input.time + 0.6)
      @auto_done_at = done
      ctx.request_repaint
      if ctx.input.time >= done
        rec.save(SAVE_PATH)
        offs = rec.offsets
        puts "[auto] saved #{rec.events.size} events, " \
             "#{offs.size} offset samples, " \
             "net y=#{offs.empty? ? "?" : (offs.last.y - offs.first.y).round(1)}"
        exit(0)
      end
    end
    ctx.top_panel("oracle_bar", height: 44.0) do |ui|
      if ui.button("Stop").clicked?
        rec.stop
        rec.stop_replay
      end
      if ui.button("Load").clicked?
        n = rec.load(NATIVE_PATH)
        rec.stop_replay
        @load_msg = n > 0 ? "loaded #{n} events" : "load FAILED"
      end
      if ui.button("Play").clicked?
        rec.start_replay
        @load_msg = "replaying…"
      end
      if ui.button("Save").clicked?
        rec.stop
        rec.save(SAVE_PATH)
        @load_msg = "saved"
      end
      state = rec.replaying? ? "replaying…" : (rec.recording? ? "recording…" : "idle")
      pos, total = rec.replay_pos
      progress = total.zero? ? "" : "  [#{pos}/#{total}]"
      ui.label("#{state}#{progress} #{@load_msg}  ev: #{rec.events.size}  " \
               "off: #{rec.offsets.size}")
    end

    ctx.central_panel("oracle_scroll") do |ui|
      area = Egui::ScrollArea.new(id: AREA_ID).content { |inner|
        # Painter coordinates are absolute window space — the scroll
        # translation lives in the inner Ui's origin (viewport.min -
        # draw_offset), so anchor the stripes to the allocated rect's
        # (already translated) top instead of raw (0, y).
        content = inner.allocate_space(Egui::Vec2.new(inner.available_width,
          ROWS * ROW_H))
        ROWS.times do |i|
          y = content.top + i * ROW_H
          color = (i % 2).zero? \
            ? Egui::Color32.rgb(217, 230, 255) \
            : Egui::Color32.rgb(255, 255, 255)
          inner.painter.rect_replace(
            Egui::Rect.from_min_size(
              Egui::Pos2.new(content.left, y),
              Egui::Vec2.new(content.width, ROW_H - 2.0)), color)
          inner.painter.text(Egui::Pos2.new(content.left + 12.0,
              y + (ROW_H - 14.0) / 2.0),
            "row #{i}", 13.0, Egui::Color32.rgb(30, 30, 30))
        end
      }
      ui.add(area)

      # The offset the widget actually scrolled by this frame — read
      # from the same state cell (Memory IdTypeMap) render and kinetics
      # use, so the sample equals the on-screen position. `sy` is the
      # frame's raw input scroll, `active` the sink arbitration
      # verdict, and `diag` the arbitration inputs: pointer position,
      # last frame's sink (contains?/can_v) — a frozen offset with
      # sy≠0 and active=false is explained by one of them.
      pos = ctx.input.pointer_pos
      sink = ctx.memory.prev_scroll_sink(AREA_ID)
      hit = ctx.memory.active_scroll_area?
      diag = "#{pos.try(&.x.round(1))},#{pos.try(&.y.round(1))}" \
        " sink=#{sink ? "1" : "0"}" \
        " in=#{sink && pos && sink.rect.contains?(pos) ? 1 : 0}" \
        " cv=#{sink.try(&.can_v) ? 1 : 0}" \
        " hit=#{hit ? "area" : "nil"}"
      Egui::ScrollRecorder.record_offset(
        ctx.memory.data.get_vec2(AREA_ID, Egui::Vec2.zero).y,
        ctx.input.scroll.y,
        ctx.memory.active_scroll_area? == AREA_ID, diag)
    end
  end
end

Egui.run(EguiScrollApp.new, title: "egui scroll oracle",
  width: 520, height: 640, inspector: :hidden)
