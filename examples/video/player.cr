# VideoPlayer: demux → decode → sws_scale to RGBA → push into an
# egui-cr stream texture. Synchronous decode on the UI thread, paced
# by a monotonic master clock against frame PTS: each UI frame decodes
# at most a few frames (catch-up budget), so a stall resyncs the clock
# instead of freezing the UI. Audio is out of scope (just for fun).

class VideoPlayer
  enum State
    Closed
    Playing
    Paused
    Eof
  end

  getter state : State = State::Closed
  getter width : Int32 = 0
  getter height : Int32 = 0
  getter duration : Float64 = 0.0
  getter texture_id : UInt64 = 0_u64
  getter error : String? = nil
  getter path : String? = nil

  @fmt : LibFF::AVFormatContext*? = nil
  @codec_ctx : LibFF::AVCodecContext*? = nil
  @frame : LibFF::AVFrame*? = nil
  @packet : LibFF::AVPacket*? = nil
  @sws : Void*? = nil
  @rgba : Bytes = Bytes.empty
  @stream_index : Int32 = -1
  @time_base : LibFF::AVRational = LibFF::AVRational.new(num: 0, den: 1)
  @frame_dur : Float64 = 1.0 / 30.0
  # PTS of the frame currently shown, and of the next one to decode.
  @shown_pts : Float64 = 0.0
  @next_pts : Float64 = 0.0
  # master clock: video seconds at @clock_origin monotonic seconds
  @clock_origin : Float64 = 0.0
  @frame_count : Int32 = 0
  @fps_accum : Float64 = 0.0
  @fps_frames : Int32 = 0
  # Newest decoded frame is in @rgba but not on the GPU yet (batched:
  # one texture upload per UI frame — sokol's once-per-frame rule).
  @pending_blit : Bool = false
  getter decode_fps : Float64 = 0.0

  # Monotonic clock epoch (the codebase's Time.instant pattern: spans
  # against a fixed start, not wall-clock seconds).
  CLOCK_START = Time.instant

  private def now_sec : Float64
    (Time.instant - CLOCK_START).total_seconds
  end

  # The registry is read lazily (ctx.textures at call time): the sokol
  # backend installs the real GPU registry only inside run(), so an
  # eagerly captured one would be the headless dummy.
  def initialize(@ctx : Egui::Context)
    LibFF.av_log_set_level(LibFF::AV_LOG_ERROR)
  end

  def playing? : Bool
    @state == State::Playing
  end

  def open? : Bool
    @state != State::Closed
  end

  # Current playback position in seconds (from the master clock while
  # playing, from the shown frame otherwise).
  def position : Float64
    return @shown_pts unless playing?
    (now_sec - @clock_origin)
      .clamp(0.0, duration > 0 ? duration : Float64::MAX)
  end

  def open(path : String) : Bool
    close
    # avformat_open_input allocates the context itself when *ctx is NULL
    fmt_ptr = Pointer(LibFF::AVFormatContext).null
    code = LibFF.avformat_open_input(pointerof(fmt_ptr), path.to_unsafe, nil, nil)
    if code < 0 || fmt_ptr.null?
      @error = "open failed: #{FF.error_string(code)}"
      return false
    end
    @fmt = fmt_ptr
    if LibFF.avformat_find_stream_info(fmt_ptr, nil) < 0
      @error = "no stream info"
      close
      return false
    end

    # best video stream (+ its decoder) — av_find_best_stream ranks
    # candidates properly instead of "first with codec_type VIDEO",
    # which can pick cover-art or low-res dub tracks in multi-stream
    # containers
    dec_ptr = Pointer(Void).null
    idx = LibFF.av_find_best_stream(fmt_ptr, LibFF::AVMEDIA_TYPE_VIDEO,
      -1, -1, pointerof(dec_ptr), 0)
    if idx < 0
      @error = "no video stream"
      close
      return false
    end
    st = fmt_ptr.value.streams[idx]
    par = st.value.codecpar.value
    @stream_index = st.value.index
    @time_base = st.value.time_base

    codec = dec_ptr
    codec = LibFF.avcodec_find_decoder(par.codec_id) if codec.null?
    if codec.null?
      @error = "no decoder for codec #{FF.codec_name(par.codec_id)}"
      close
      return false
    end
    cctx = LibFF.avcodec_alloc_context3(codec)
    if LibFF.avcodec_parameters_to_context(cctx, st.value.codecpar) < 0 ||
       LibFF.avcodec_open2(cctx, codec, nil) < 0
      @error = "decoder init failed"
      LibFF.avcodec_free_context(pointerof(cctx))
      close
      return false
    end
    cctx.value.pkt_timebase = @time_base
    # Slice threading: auto count — big decode win on H.264/HEVC, safe
    # from a single calling thread. EXCEPT VP8/VP9 decoders: the native
    # vp8 decoder (and libvpx) output all-zero planes with threads
    # enabled inside this app's process (fine in a plain CLI process —
    # root cause not identified, bisected via EGUI_VIDEO_THREADS), so
    # those run single-threaded. VP8/VP9 stay fast enough at web sizes.
    if (dn = FF.decoder_name(codec)).starts_with?("vp8") || dn.starts_with?("libvpx")
      cctx.value.thread_count = 1
      cctx.value.thread_type = 0
    else
      cctx.value.thread_count = 0
      cctx.value.thread_type = 2 # FF_THREAD_SLICE
    end
    if (t = ENV["EGUI_VIDEO_THREADS"]?)
      count, _, ttype = t.partition(':')
      cctx.value.thread_count = count.to_i? || 0
      cctx.value.thread_type = ttype.to_i? || 0
    end
    @codec_ctx = cctx

    @frame = LibFF.av_frame_alloc
    @packet = LibFF.av_packet_alloc

    @width = par.width > 0 ? par.width : cctx.value.width
    @height = par.height > 0 ? par.height : cctx.value.height
    dur = st.value.duration
    @duration = dur > 0 ? pts_to_seconds(dur)
                        : fmt_ptr.value.duration > 0 ? fmt_ptr.value.duration / 1_000_000.0 : 0.0
    avg = st.value.avg_frame_rate
    @frame_dur = avg.den > 0 && avg.num > 0 ? avg.den.to_f64 / avg.num : 1.0 / 30.0

    @rgba = Bytes.new(@width * @height * 4)
    @texture_id = @ctx.textures.create_stream(@width, @height)
    if @texture_id.zero?
      @error = "texture creation failed"
      close
      return false
    end

    @path = path
    @error = nil
    @frame_count = 0
    # decode + show the first frame right away
    return false unless decode_next_frame
    blit
    @state = State::Paused
    play
    true
  end

  def play : Nil
    return unless @state == State::Paused || @state == State::Eof
    if @state == State::Eof
      return unless seek(0.0)
    end
    @clock_origin = now_sec - @shown_pts
    @state = State::Playing
  end

  def pause : Nil
    return unless @state == State::Playing
    @shown_pts = position
    @state = State::Paused
  end

  def toggle : Nil
    playing? ? pause : play
  end

  def stop : Nil
    close
  end

  # Release everything and go back to the placeholder state.
  def close : Nil
    if (sws = @sws)
      LibFF.sws_free_context(sws)
      @sws = nil
    end
    if @packet
      pkt = @packet.not_nil!
      LibFF.av_packet_free(pointerof(pkt))
      @packet = nil
    end
    if @frame
      frame = @frame.not_nil!
      LibFF.av_frame_free(pointerof(frame))
      @frame = nil
    end
    if @codec_ctx
      cctx = @codec_ctx.not_nil!
      LibFF.avcodec_free_context(pointerof(cctx))
      @codec_ctx = nil
    end
    if @fmt
      fmt = @fmt.not_nil!
      LibFF.avformat_close_input(pointerof(fmt))
      @fmt = nil
    end
    unless @texture_id.zero?
      @ctx.textures.destroy(@texture_id)
      @texture_id = 0_u64
    end
    @state = State::Closed
    @path = nil
    @shown_pts = @next_pts = 0.0
    @frame_count = 0
  end

  # Called every UI frame while a file is open. While playing, decodes
  # forward until the shown frame is the one due at the master clock
  # (bounded catch-up budget: a slow decode resyncs the clock rather
  # than freezing the UI).
  def advance : Nil
    return unless playing?
    now = now_sec
    budget = 8
    while budget > 0 && @next_pts <= now - @clock_origin
      break unless decode_next_frame
      budget -= 1
    end
    if budget.zero?
      # fell behind (slow decode / debugger pause): resync, don't race
      @clock_origin = now - @shown_pts
    end
    # Past the last frame: drain the demuxer so the decoder reports EOF
    # (flips state to Eof — Play then restarts from the beginning).
    decode_next_frame if duration > 0.0 && position >= duration
    blit
    debug_tick
  end

  # EGUI_VIDEO_DEBUG=1: one stderr line per second — the smoke test's
  # window into decode pacing without any screenshot tooling.
  @@debug_last : Float64 = -1.0
  @@advance_calls : Int32 = 0
  @@decode_calls : Int32 = 0

  private def debug_tick : Nil
    @@advance_calls += 1
    return unless ENV["EGUI_VIDEO_DEBUG"]?
    if now_sec - @@debug_last >= 1.0
      @@debug_last = now_sec
      r, g, b, a = {@rgba[0]?, @rgba[1]?, @rgba[2]?, @rgba[3]?}
      # subsampled average color — the green-screen detector (pure green
      # avg = zeroed YUV planes converted, i.e. a broken source path)
      ar = avg_channel(0); ag = avg_channel(1); ab = avg_channel(2)
      upd_ms, upd_n = VideoApp.take_update_stats
      STDERR.printf("video: %-7s pts=%6.2f frames=%-5d fps=%.1f px0=%d,%d,%d,%d avg=%d,%d,%d adv=%d dec=%d blit=%.0fms upd=%.0fms/%d\n",
        @state.to_s.downcase, @shown_pts, @frame_count, @decode_fps,
        r || -1, g || -1, b || -1, a || -1, ar, ag, ab,
        @@advance_calls, @@decode_calls, @@blit_ms, upd_ms, upd_n)
      @@advance_calls = 0
      @@decode_calls = 0
      @@blit_ms = 0.0
    end
  end

  # Average of one RGBA channel over a 1/64 pixel subsample.
  private def avg_channel(idx : Int32) : Int32
    return 0 if @rgba.empty?
    step = 64 * 4
    sum = 0
    n = 0
    i = idx
    while i < @rgba.size
      sum += @rgba[i]
      n += 1
      i += step
    end
    n > 0 ? sum // n : 0
  end

  # Seek to a position in seconds: jump to the previous keyframe, then
  # decode forward to the target. Returns false on failure.
  def seek(target : Float64) : Bool
    fmt = @fmt
    return false unless fmt
    target = target.clamp(0.0, duration > 0 ? duration : target)
    # stream_index -1 → timestamps in AV_TIME_BASE (microseconds);
    # wide-open bounds + BACKWARD = "previous keyframe at or before ts"
    ts = (target * 1_000_000).to_i64
    code = LibFF.avformat_seek_file(fmt, -1,
      Int64::MIN, ts, Int64::MAX, LibFF::AVSEEK_FLAG_BACKWARD)
    if code < 0
      @error = "seek failed: #{FF.error_string(code)}"
      return false
    end
    if (cctx = @codec_ctx)
      LibFF.avcodec_flush_buffers(cctx)
    end
    # decode up to the target (or the nearest earlier frame)
    guard = 600
    while guard > 0
      break unless decode_next_frame
      break if @shown_pts + @frame_dur * 0.5 >= target
      guard -= 1
    end
    blit
    @clock_origin = now_sec - @shown_pts if playing?
    true
  end

  # --- internals ----------------------------------------------------------

  # Land in the Eof state: freeze at the end position (Play restarts
  # from the beginning from there).
  private def mark_eof : Nil
    return if @state == State::Eof
    @state = State::Eof
    @shown_pts = duration > 0 ? duration : @shown_pts
    STDERR.puts("video: eof") if ENV["EGUI_VIDEO_DEBUG"]?
  end

  private def pts_to_seconds(pts : Int64) : Float64
    pts.to_f64 * @time_base.num / @time_base.den
  end

  # Decode the next frame, convert to RGBA and push it into the
  # texture. Returns false at EOF (state → Eof) or error.
  private def decode_next_frame : Bool
    @@decode_calls += 1
    fmt = @fmt.not_nil!
    cctx = @codec_ctx.not_nil!
    frame = @frame.not_nil!
    pkt = @packet.not_nil!

    loop do
      code = LibFF.avcodec_receive_frame(cctx, frame)
      if code == 0
        convert_frame(frame)
        return true
      end
      if code == LibFF::AVERROR_EOF
        # decoder fully flushed (a previous call already sent the
        # end-of-stream) — land in Eof here too, not just from the
        # demux path below
        mark_eof
        return false
      end
      if code != LibFF::AVERROR_EAGAIN
        @error = "decode failed: #{FF.error_string(code)}"
        return false
      end

      # decoder is hungry: feed it the next video packet
      loop do
        code = LibFF.av_read_frame(fmt, pkt)
        if code == LibFF::AVERROR_EOF
          # flush the decoder, then EOF
          LibFF.avcodec_send_packet(cctx, nil)
          drain = LibFF.avcodec_receive_frame(cctx, frame)
          if drain == 0
            convert_frame(frame)
            return true
          end
          mark_eof
          return false
        elsif code < 0
          @error = "read failed: #{FF.error_string(code)}"
          return false
        end
        if pkt.value.stream_index == @stream_index
          send = LibFF.avcodec_send_packet(cctx, pkt)
          LibFF.av_packet_unref(pkt)
          if send < 0 && send != LibFF::AVERROR_EAGAIN && send != LibFF::AVERROR_EOF
            @error = "send failed: #{FF.error_string(send)}"
            return false
          end
          break # packet sent — back to receive
        end
        LibFF.av_packet_unref(pkt) # not ours: keep reading
      end
    end
  end

  # sws_scale the decoded frame into @rgba. GPU-side: none — the
  # upload is batched per UI frame (see #blit), because sokol allows
  # ONE sg_update_image per image and frame, and the catch-up decode
  # can produce several frames between two repaints. Only the newest
  # frame's pixels are displayed, so batching is also cheaper.
  private def convert_frame(frame : LibFF::AVFrame*) : Nil
    fw = frame.value.width
    fh = frame.value.height
    if fw != @width || fh != @height || @sws.nil?
      # stream parameters changed mid-flight: rebuild scaler + texture
      @width = fw
      @height = fh
      if (sws = @sws)
        LibFF.sws_free_context(sws)
      end
      @rgba = Bytes.new(fw * fh * 4)
      unless @texture_id.zero?
        @ctx.textures.destroy(@texture_id)
      end
      @texture_id = @ctx.textures.create_stream(fw, fh)
      @sws = nil
      @pending_blit = false # fresh texture: nothing stale to push
    end
    unless (sws = @sws)
      dst_fmt = LibFF.av_get_pix_fmt("rgba".to_unsafe)
      sws = LibFF.sws_get_context(fw, fh, frame.value.format,
        fw, fh, dst_fmt, LibFF::SWS_BILINEAR, nil, nil, nil)
      @sws = sws
    end
    src = frame.value.data
    src_stride = frame.value.linesize
    dst_ptr = @rgba.to_unsafe
    dst_stride = fw * 4
    LibFF.sws_scale(sws, src.to_unsafe, src_stride.to_unsafe, 0, fh,
      pointerof(dst_ptr), pointerof(dst_stride))
    if ENV["EGUI_VIDEO_DEBUG"]? && @frame_count.zero?
      y, u, v = src[0]?, src[1]?, src[2]?
      ys = y ? y.to_slice(8).map(&.to_s).join(",") : "null"
      us = u ? u.to_slice(4).map(&.to_s).join(",") : "null"
      vs = v ? v.to_slice(4).map(&.to_s).join(",") : "null"
      STDERR.puts("convert f1: #{fw}x#{fh} fmt=#{frame.value.format} " \
                  "Y=#{ys} U=#{us} V=#{vs} rgba0=#{@rgba[0]},#{@rgba[1]},#{@rgba[2]},#{@rgba[3]}")
    end
    @pending_blit = true

    # frame pts is in pkt_timebase units (== stream time_base); fall
    # back to best_effort_timestamp / frame-duration cadence
    pts = frame.value.pts
    pts = frame.value.best_effort_timestamp if pts == LibFF::NOPTS || pts < 0
    @shown_pts = pts != LibFF::NOPTS && pts >= 0 ? pts_to_seconds(pts) : @shown_pts + @frame_dur
    @next_pts = @shown_pts + @frame_dur
    @frame_count += 1

    # decode fps meter (1 s window)
    @fps_accum += @frame_dur
    @fps_frames += 1
    if @fps_accum >= 1.0
      @decode_fps = @fps_frames / @fps_accum
      @fps_accum = 0.0
      @fps_frames = 0
    end
  end

  # Push the newest converted frame to the GPU — at most once per UI
  # frame (sokol: one sg_update_image per image and frame).
  @@blit_ms : Float64 = 0.0

  private def blit : Nil
    return unless @pending_blit
    t0 = Time.instant
    @ctx.textures.update(@texture_id, @width, @height, @rgba) unless @texture_id.zero?
    @@blit_ms += (Time.instant - t0).total_milliseconds
    @pending_blit = false
  end
end
