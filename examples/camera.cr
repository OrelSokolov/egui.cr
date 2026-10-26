# egui-cr camera demo — a separate binary (bin/camera).
#
# Framework side: the Camera seam (src/egui/camera.cr) — AVFoundation on
# macOS, camera2 NDK on Android, V4L2 on Linux, "not implemented" on iOS
# and Windows for now. Frames flow Session#poll (RGBA) →
# TextureRegistry#create_stream/#update, the same pipeline the video
# player uses. Device picker, runtime permission (mobile) and start/stop;
# platforms without a native stack get the honest message instead.

require "../src/egui/backend_selector"

class CameraApp < Egui::App
  @devices = [] of Egui::Camera::Device
  @names = [] of String
  @selected = -1
  @session : Egui::Camera::Session? = nil
  @texture_id = 0_u64
  @tex_w = 0
  @tex_h = 0
  @frames = 0
  @status = ""
  @listed = false
  @perm_requested = false
  @rotation = 0
  @video_mode = false

  def initialize
    super()
  end

  private def stop_capture : Nil
    @session.try &.close
    @session = nil
    @frames = 0
    if @texture_id != 0
      ctx.textures.destroy(@texture_id)
      @texture_id = 0_u64
    end
  end

  private def start_capture : Nil
    stop_capture
    device = @selected >= 0 ? @devices[@selected]? : nil
    session = Egui::Camera.open(device.try &.id, 1280, 720)
    if session
      session.rotation = @rotation
      session.video_mode = @video_mode
      @session = session
      @status = "Starting…"
    else
      @status = "Open failed: #{Egui::Camera.last_error || "unknown error"}"
    end
  end

  def update(ctx : Egui::Context) : Nil
    # Device list + permission state, lazily on the first update.
    unless @listed
      @listed = true
      if Egui::Camera.available?
        refresh_devices
        @status = "Pick a camera and press Start."
      end
    end

    # The permission dialog (mobile) answers asynchronously — refresh the
    # device list once granted (on Android it fills only then).
    granted = Egui::Camera.available? && Egui::Camera.permission_granted?
    if granted
      @perm_requested = false
      refresh_devices if @selected < 0
    elsif @perm_requested
      # The OS dialog resolves with NO event into the app — without this
      # the UI would sit on the Allow button until the next input.
      ctx.request_repaint
    end

    # Frame pump: one poll per UI frame; nil until a NEW frame arrived.
    if (session = @session)
      if (rgba = session.poll)
        if @texture_id != 0 && (@tex_w != session.width || @tex_h != session.height)
          # Format change (device switch, preset renegotiation): the
          # stream texture is size-locked, rebuild it.
          ctx.textures.destroy(@texture_id)
          @texture_id = 0_u64
        end
        if @texture_id == 0
          @texture_id = ctx.textures.create_stream(session.width, session.height)
          @tex_w = session.width
          @tex_h = session.height
        end
        ctx.textures.update(@texture_id, session.width, session.height, rgba)
        @frames += 1
        @status = "#{session.width}×#{session.height} · frame #{@frames}"
      end
      ctx.request_repaint # camera = continuous stream, never idle-skip
    end

    # Explicit height: a top/bottom panel without one is a ONE-LINE
    # strip (default_strip_height) — everything past the first row
    # clipped to zero height, which is why the Mode button never
    # rendered. Three lines of controls need ~120 logical px.
    ctx.bottom_panel(height: 120) do |ui|
      ui.horizontal do |row|
        unless Egui::Camera.available?
          row.label(Egui::Camera.unavailable_reason || "Camera unavailable")
          next
        end
        unless Egui::Camera.permission_granted?
          if row.button("Allow camera access").clicked?
            Egui::Camera.request_permission!
            if (err = Egui::Camera.last_error)
              @status = err
            else
              @perm_requested = true
              @status = "Waiting for permission — answer the system dialog…"
            end
          end
          row.label("Camera needs permission — tap Allow, then press Start.")
          next
        end
        if @names.empty?
          row.label("No camera devices found")
        else
          row.select_box("cam_device", @selected >= 0 ? @names[@selected] : "",
            @names) do |opt|
            idx = @names.index(opt) || 0
            if idx != @selected
              @selected = idx
              start_capture if @session # live device switch
            end
          end
          label = @session ? "Stop" : "Start"
          if row.button(label).clicked?
            @session ? stop_capture : start_capture
          end
          # Manual preview rotation in 90° steps (on top of the sensor
          # orientation fix) — live when capturing, remembered for the
          # next Start.
          if row.button("Rotate #{@rotation}°").clicked?
            @rotation = (@rotation + 90) % 360
            @session.try &.rotation = @rotation
          end
        end
      end
      {% if flag?(:android) %}
        # camera2 capture template switch: Video = RECORD + the
        # highest fixed fps range + EIS/OIS (the system camera's
        # video mode), Photo = the conservative PREVIEW default.
        # Its own row — four buttons don't fit a phone-wide panel.
        if ui.button(@video_mode ? "Mode: Video" : "Mode: Photo").clicked?
          @video_mode = !@video_mode
          @session.try &.video_mode = @video_mode
        end
      {% end %}
      ui.label(@status)
    end

    ctx.central_panel do |ui|
      if @texture_id != 0
        # fit preserving aspect ratio (the video player's sizing)
        avail = Egui::Vec2.new(ui.available_width, ui.available_height)
        scale = {@tex_w > 0 ? avail.x / @tex_w : 0.0,
                 @tex_h > 0 ? avail.y / @tex_h : 0.0,
                 1.0}.min
        ui.image(@texture_id, Egui::Vec2.new(@tex_w * scale, @tex_h * scale))
      else
        ui.heading("egui-cr camera")
        if Egui::Camera.available?
          ui.label("Live preview from the Camera seam: device picker, " \
                   "permission, RGBA frames into a stream texture.")
          ui.separator
          ui.label(@status)
        else
          ui.label(Egui::Camera.unavailable_reason || "Camera unavailable")
        end
      end
    end
  end

  private def refresh_devices : Nil
    @devices = Egui::Camera.devices
    @names = @devices.map &.to_s
    @selected = 0 unless @names.empty?
  end
end

Egui.run(CameraApp.new,
  title: "egui.cr — camera", width: 960, height: 620, inspector: :hidden)
