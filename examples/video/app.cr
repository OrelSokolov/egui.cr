# The video player egui app: central panel shows the fitted video
# surface, a bottom panel carries the controls (open, play/pause,
# stop, seek slider, time). Space toggles playback; files can be
# dropped onto the window.

class VideoApp < Egui::App
  @seek_drag = false

  # CLI arg: opened on the FIRST update, not before run() — GPU
  # textures can only exist after the sokol gfx setup (the sg view
  # would be dead otherwise).
  def initialize(@pending_open : String? = nil)
    super()
    @player = VideoPlayer.new(@ctx)
    @status = "Open a video file — or drop one onto the window."
  end

  def open_video(path : String) : Nil
    if @player.open(path)
      @status = File.basename(path)
      STDERR.puts("video: opened #{path} #{@player.width}x#{@player.height} " \
                  "dur=#{@player.duration}") if ENV["EGUI_VIDEO_DEBUG"]?
    else
      @status = "#{File.basename(path)}: #{@player.error || "cannot open"}"
      STDERR.puts("video: open FAILED: #{@player.error}") if ENV["EGUI_VIDEO_DEBUG"]?
    end
  end

  def update(ctx : Egui::Context) : Nil
    t0 = Time.instant
    # CLI arg / queued open — must run inside a frame (GPU is up)
    if (p = @pending_open)
      @pending_open = nil
      open_video(p)
    end

    # Space = play/pause (only when nothing else claimed the key)
    if @player.open? && ctx.input.key_pressed?(Egui::KeyCode::Space)
      ctx.input.consume_key(Egui::KeyCode::Space)
      @player.toggle
    end

    # Drag & drop: first path wins
    if (drop = ctx.input.dropped_files.first?)
      open_video(drop)
    end

    if @player.playing?
      @player.advance
      ctx.request_repaint # keep the vsync loop from idle-skipping
    end

    ctx.bottom_panel do |ui|
      ui.horizontal do |row|
        if row.button("Open…").clicked?
          Egui::SystemPorts::OpenFileDialog.show(
            title: "Open video",
            filters: ["*.mp4", "*.mkv", "*.webm", "*.avi", "*.mov", "*.gif"]
          ) do |path|
            open_video(path) if path
          end
        end

        if @player.open?
          if row.button(@player.playing? ? "Pause" : "Play").clicked?
            @player.toggle
          end
          if row.button("Stop").clicked?
            @player.stop
            @status = "Stopped."
          end
        end
      end

      if @player.open? && @player.duration > 0.0
        pos = @seek_drag ? seek_value : @player.position
        row_slider = ui.slider(pos.clamp(0.0, @player.duration),
          0.0..@player.duration) do |v|
          @seek_drag = true
          seek_value = v
        end
        if row_slider.drag_stopped?
          @player.seek(seek_value)
          @seek_drag = false
        end
        ui.label("#{fmt_time(@player.position)} / #{fmt_time(@player.duration)}" \
                 "  ·  #{@player.width}×#{@player.height}" \
                 "  ·  #{@player.decode_fps.round(1)} fps decode")
      else
        ui.label(@status)
      end
    end

    ctx.central_panel do |ui|
      if @player.open? && !@player.texture_id.zero?
        # fit preserving aspect ratio
        avail = Egui::Vec2.new(ui.available_width, ui.available_height)
        scale = {@player.width > 0 ? avail.x / @player.width : 0.0,
                 @player.height > 0 ? avail.y / @player.height : 0.0,
                 1.0}.min
        size = Egui::Vec2.new(@player.width * scale, @player.height * scale)
        ui.image(@player.texture_id, size)
      else
        ui.heading("egui-cr video player")
        ui.label("FFmpeg decode → RGBA → stream texture.")
        ui.separator
        ui.label(@status)
        ui.label("Space: play/pause · drop a file to open")
        if (err = @player.error)
          ui.label("last error: #{err}")
        end
      end
    end

    VideoApp.add_update_ms((Time.instant - t0).total_milliseconds)
  end

  # debug: cumulative update() duration, printed by the player's tick
  @@update_ms : Float64 = 0.0
  @@frames : Int32 = 0

  def self.add_update_ms(ms : Float64) : Nil
    @@update_ms += ms
    @@frames += 1
  end

  def self.take_update_stats : {Float64, Int32}
    s = {@@update_ms, @@frames}
    @@update_ms = 0.0
    @@frames = 0
    s
  end

  # slider drag scratch value (kept out of the player until release)
  @seek_scratch : Float64 = 0.0

  private def seek_value : Float64
    @seek_scratch
  end

  private def seek_value=(v : Float64)
    @seek_scratch = v
  end

  private def fmt_time(sec : Float64) : String
    total = sec.clamp(0.0, Float64::MAX).to_i
    "%02d:%02d" % {total // 60, total % 60}
  end
end
