require "minaudio"

@[Link("egui_video")]
lib LibVideoPool
  # backend/video_pool.c — fixed VAAPI surface pool creation (returns
  # an AVBufferRef* owned by the caller; 0 = failure)
  fun pool_create = egui_video_pool_create(device_ref : UInt8*,
                                           format : Int32,
                                           sw_format : Int32, w : Int32,
                                           h : Int32,
                                           pool_size : Int32) : UInt8*
  # AVBufferRef* → ->data (the pointed-at context) — pool identity checks
  fun ref_data = egui_video_ref_data(ref : UInt8*) : UInt8*
  # Direct per-surface dmabuf export (see backend/video_pool.c for the
  # out[12] layout). Returns 0 on success; out[0] is an OWNED fd.
  fun export_surface = egui_video_export_surface(device_ref : UInt8*,
                                                 surface : UInt32,
                                                 out : Int64*) : Int32
  # vaSyncSurface through the VAAPI device context — the per-frame
  # decode-write barrier (what av_hwframe_map did implicitly)
  fun sync_surface = egui_video_sync_surface(device_ref : UInt8*,
                                             surface_id : UInt32) : Int32
end

class VideoPlayer
  enum State
    Closed
    Playing
    Paused
    Eof
  end

  # A run of interleaved-f32 PCM with its media pts (seconds) — the unit
  # the audio feeder queues, drops (stale) and pads (gaps) with.
  struct AudioChunk
    getter pts : Float64
    getter pcm : Bytes
    getter frames : Int32

    def initialize(@pts : Float64, @pcm : Bytes, @frames : Int32)
    end

    def dur(rate : Int32) : Float64
      @frames.to_f64 / rate
    end

    def advance(n : Int32, channels : Int32, rate : Int32) : AudioChunk
      AudioChunk.new(@pts + n.to_f64 / rate,
        @pcm + (n * channels * 4), @frames - n)
    end
  end

  # export-once-per-surface entry (the gstvaallocator model): the
  # geometry of one pool surface's dmabuf plus the exported fd WE keep
  # open for the surface's whole life. No frame refs: the fd pins the
  # dmabuf, the surface returns to the decode pool, and when the pool
  # recycles it the SAME dmabuf carries the new frame (the R-side
  # VkImage reads fresh content by inode identity).
  struct ZcExport
    getter fd : Int32
    getter size : Int32
    getter w : Int32
    getter h : Int32
    getter pitch_y : Int32
    getter pitch_uv : Int32
    getter off_y : Int32
    getter off_uv : Int32
    getter modifier : UInt64
    getter fc_y : UInt32
    getter fc_uv : UInt32

    def initialize(@fd : Int32, @size : Int32, @w : Int32, @h : Int32,
                   @pitch_y : Int32, @pitch_uv : Int32, @off_y : Int32,
                   @off_uv : Int32, @modifier : UInt64, @fc_y : UInt32,
                   @fc_uv : UInt32)
    end
  end

  getter state : State = State::Closed
  getter width : Int32 = 0
  getter height : Int32 = 0
  getter duration : Float64 = 0.0
  getter texture_id : UInt64 = 0_u64
  getter error : String? = nil
  getter path : String? = nil
  getter audio_rate : Int32 = 0
  getter audio_channels : Int32 = 0
  getter audio_codec : String? = nil
  getter video_codec : String? = nil
  # why audio is silent despite an audio stream (no device, decode fail)
  getter audio_note : String? = nil

  @fmt : LibFF::AVFormatContext*? = nil
  @codec_ctx : LibFF::AVCodecContext*? = nil
  @frame : LibFF::AVFrame*? = nil
  @packet : LibFF::AVPacket*? = nil
  @sws : Void*? = nil
  @rgba : Bytes = Bytes.empty
  @stream_index : Int32 = -1
  @time_base : LibFF::AVRational = LibFF::AVRational.new(num: 0, den: 1)
  # stream start offset (MPEG-TS etc. start at 1.4 s, not 0): every media
  # time the app sees is start-relative — positions, durations, seeks
  @start_off : Float64 = 0.0
  @frame_dur : Float64 = 1.0 / 30.0
  # PTS of the frame currently shown (decode frontier for pacing), and
  # of the next one to decode. @display_pts tracks the newest CONVERTED
  # frame (what is actually on screen — debug/A-V sync metric; decode
  # can run a LEAD ahead of it feeding audio).
  @shown_pts : Float64 = 0.0
  @display_pts : Float64 = 0.0
  @next_pts : Float64 = 0.0
  # wall-clock fallback master: video seconds at @clock_origin monotonic s
  @clock_origin : Float64 = 0.0
  @frame_count : Int32 = 0
  # real decode rate: frames per WALL second (the old media-time
  # accumulator always printed the nominal fps — useless as a
  # "keeping up" signal)
  @fps_frames : Int32 = 0
  @fps_wall : Float64 = 0.0
  @pending_blit : Bool = false
  getter decode_fps : Float64 = 0.0

  # --- audio ---
  @a_fmt : LibFF::AVFormatContext*? = nil
  @a_codec_ctx : LibFF::AVCodecContext*? = nil
  @a_frame : LibFF::AVFrame*? = nil
  @a_packet : LibFF::AVPacket*? = nil
  @a_index : Int32 = -1
  @a_time_base : LibFF::AVRational = LibFF::AVRational.new(num: 0, den: 1)
  @a_start_off : Float64 = 0.0
  @ring : MinAudio::PlaybackRing? = nil
  @a_frames : Array(AudioChunk) = [] of AudioChunk
  @a_next_pts : Float64 = Float64::NAN # media pts at the backlog tail
  @a_eof : Bool = false
  # audio clock anchor: media pts at @a_base_consumed played frames
  @a_base_pts : Float64 = 0.0
  @a_base_consumed : UInt64 = 0_u64
  @video_eof : Bool = false
  # output volume (applies to the ring; re-applied when a new ring opens)
  @volume : Float32 = 1.0f32

  # how much decoded audio to keep ahead of the clock (s), and the ring
  # capacity (s) absorbing UI-frame hiccups
  AUDIO_LEAD  = 0.30
  AUDIO_RING  = 1.00
  # drop/pad tolerance for discontinuities (s)
  AUDIO_EPS   = 0.02
  @@a_written : Int32 = 0  # debug counter
  @@a_dropped : Int32 = 0
  @@a_padded  : Int32 = 0

  CLOCK_START = Time.instant

  private def now_sec : Float64
    (Time.instant - CLOCK_START).total_seconds
  end

  def initialize(@ctx : Egui::Context)
    LibFF.av_log_set_level(
      (ENV["EGUI_VIDEO_AVLOG"]?.try &.to_i?) || LibFF::AV_LOG_ERROR)
  end

  def playing? : Bool
    @state == State::Playing
  end

  # Volume 0..1 — straight to the playback device, remembered for the
  # next open (files without audio simply store it).
  def volume=(v : Float32) : Nil
    @volume = v.clamp(0.0f32, 1.0f32)
    @ring.try(&.volume = @volume)
  end

  def volume : Float32
    @volume
  end

  def open? : Bool
    @state != State::Closed
  end

  # True while the adaptive pipeline DOWNSCALES below the native source
  # resolution (quality traded for frame rate) — the UI marks it.
  def downscaled? : Bool
    return false if @lad.empty?
    native = @lad[0]
    (@lad[@li]? || native) < native
  end

  def audio? : Bool
    !@ring.nil?
  end

  # The audio master clock: media seconds corresponding to the frame the
  # device is playing right now (underrun silence keeps it contiguous).
  private def audio_clock : Float64
    ring = @ring
    return @shown_pts unless ring
    @a_base_pts +
      (ring.consumed_frames - @a_base_consumed).to_f64 / @audio_rate
  end

  # Current playback position in seconds (audio clock while playing with
  # audio, wall clock without, shown frame otherwise).
  def position : Float64
    return @shown_pts unless playing?
    t = @ring ? audio_clock : now_sec - @clock_origin
    t.clamp(0.0, duration > 0 ? duration : Float64::MAX)
  end

  def open(path : String) : Bool
    close
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
    @video_codec = FF.codec_name(par.codec_id)
    st_start = st.value.start_time
    if st_start != LibFF::NOPTS && st_start > 0
      @start_off = st_start.to_f64 * @time_base.num / @time_base.den
    else
      @start_off = 0.0
    end

    codec = dec_ptr
    codec = LibFF.avcodec_find_decoder(par.codec_id) if codec.null?
    if codec.null?
      @error = "no decoder for codec #{FF.codec_name(par.codec_id)}"
      close
      return false
    end
    cctx = LibFF.avcodec_alloc_context3(codec)
    if LibFF.avcodec_parameters_to_context(cctx, st.value.codecpar) < 0
      @error = "decoder init failed"
      LibFF.avcodec_free_context(pointerof(cctx))
      close
      return false
    end
    cctx.value.pkt_timebase = @time_base
    if (dn = FF.decoder_name(codec)).starts_with?("vp8") || dn.starts_with?("libvpx")
      cctx.value.thread_count = 1
      cctx.value.thread_type = 0
    else
      cctx.value.thread_count = 0
      # FF_THREAD_FRAME (1): what mpv/ffplay use — H264/HEVC decode
      # scales near-linearly with cores. Slice threading (2) splits ONE
      # frame and stalls at 2-3× on big resolutions; frame threading
      # decodes several frames at once, which is what heavy 4K/6K files
      # need to keep up with realtime.
      cctx.value.thread_type = 1
    end
    if (t = ENV["EGUI_VIDEO_THREADS"]?)
      count, _, ttype = t.partition(':')
      cctx.value.thread_count = count.to_i? || 0
      cctx.value.thread_type = ttype.to_i? || 0
    end
    # hw decode BEFORE open2: hw_device_ctx must be attached when the
    # decoder initializes (get_format then offers the VAAPI pix fmt)
    hw = setup_hw(cctx)
    if hw && !@@zc_dead && LibEguiCr.video_supported != 0 &&
       ENV["EGUI_VIDEO_ZC"]? != "0" && (dev = @hw_device)
      # The pool must match what the DECODER will output: probe it by
      # decoding one frame (see #probe_hw_params) — a wrong sw_format
      # guess makes ffmpeg drop our fixed pool for a dynamic one.
      sw_fmt, pw, ph = probe_hw_params(path, codec) ||
        {par.format == 62 ? 158 : 23, # P010LE / NV12 (container hint)
         @width > 0 ? @width : par.width,
         @height > 0 ? @height : par.height}
      unless (fref = LibVideoPool.pool_create(dev, @@hw_pix_fmt,
               sw_fmt, pw, ph, 34)).null?
        # GStreamer-style FIXED surface pool (gstvaallocator): surfaces
        # pre-allocated once, recycled by the decoder forever — the
        # dynamic pool allocated a NEW surface per frame (unique dmabuf
        # inodes → export+import churn → the ~700-frame degradation).
        # Struct writes live in C (backend/video_pool.c) — Crystal-side
        # offsets kept drifting. ONLY under zc: the copy-back fallback
        # needs the decoder's own pool (scale_vaapi refuses ours).
        cctx.value.hw_frames_ctx = LibFF.av_buffer_ref(fref)
        cctx.value.extra_hw_frames = 8
        @zc_frames = fref
        # the get_format callback re-attaches this ref on the decoding
        # context (ffmpeg strips the pre-open2 attach — see HW_GET_FORMAT)
        @@hw_pool_ref = fref
        @zc = true
        @video_id = LibEguiCr.video_create
        @video_texture_id = @video_id.to_u64
        STDERR.puts("video: zero-copy path (Vulkan), fixed pool") if ENV["EGUI_VIDEO_DEBUG"]?
      end
    end
    if LibFF.avcodec_open2(cctx, codec, nil) < 0
      detach_hw(cctx) if hw # hw may be why open failed — retry software
      if hw && LibFF.avcodec_open2(cctx, codec, nil) < 0
        hw = false
      end
      unless hw
        @error = "decoder init failed"
        LibFF.avcodec_free_context(pointerof(cctx))
        close
        return false
      end
    end
    @codec_ctx = cctx
    if ENV["EGUI_VIDEO_DEBUG"]? && @zc
      still = cctx.value.hw_frames_ctx == @zc_frames ||
              LibVideoPool.ref_data(cctx.value.hw_frames_ctx) ==
              LibVideoPool.ref_data(@zc_frames.not_nil!)
      STDERR.puts("video: zc pool on cctx after open2: #{still}")
    end

    @frame = LibFF.av_frame_alloc
    @packet = LibFF.av_packet_alloc

    @width = par.width > 0 ? par.width : cctx.value.width
    @height = par.height > 0 ? par.height : cctx.value.height
    dur = st.value.duration
    # st.duration / fmt.duration are start-relative (end − start), unlike
    # frame pts — no @start_off subtraction here
    if dur > 0
      @duration = dur.to_f64 * @time_base.num / @time_base.den
    elsif fmt_ptr.value.duration > 0
      @duration = fmt_ptr.value.duration / 1_000_000.0
    else
      @duration = 0.0
    end
    avg = st.value.avg_frame_rate
    @frame_dur = avg.den > 0 && avg.num > 0 ? avg.den.to_f64 / avg.num : 1.0 / 30.0

    unless @zc # zero-copy owns no CPU pixels — the copy-back texture
                # materializes lazily on fallback (see #convert_frame)
      @rgba = Bytes.new(@width * @height * 4)
      @texture_id = @ctx.textures.create_stream(@width, @height)
      if @texture_id.zero?
        @error = "texture creation failed"
        close
        return false
      end
    end

    open_audio(path)

    @path = path
    @error = nil
    @frame_count = 0
    if ENV["EGUI_VIDEO_DEBUG"]? && @zc
      m2 = LibVideoPool.ref_data(@codec_ctx.not_nil!.value.hw_frames_ctx) ==
           LibVideoPool.ref_data(@zc_frames.not_nil!)
      STDERR.puts("video: zc pool before first decode: #{m2} " \
                  "(raw=#{@codec_ctx.not_nil!.value.hw_frames_ctx.address})")
    end
    return false unless decode_next_frame
    blit
    prebuffer_audio(@shown_pts)
    @state = State::Paused
    play
    true
  end

  # Best audio stream + decoder + the playback ring. Fully degradable:
  # no audio stream / no decoder / no device → video-only, wall clock.
  #
  # Audio demuxes through its OWN AVFormatContext on the same file: one
  # shared demuxer would couple the streams' pacing (feeding audio LEAD
  # ahead means reading video packets early — and frames pulled past
  # their display moment are gone forever). Two independent contexts
  # read/seek/EOF on their own timelines; both report time in seconds,
  # so the streams stay on one clock.
  private def open_audio(path : String) : Nil
    afmt_ptr = Pointer(LibFF::AVFormatContext).null
    code = LibFF.avformat_open_input(pointerof(afmt_ptr), path.to_unsafe, nil, nil)
    if code < 0 || afmt_ptr.null?
      @audio_note = "audio open failed: #{FF.error_string(code)}"
      return
    end
    if LibFF.avformat_find_stream_info(afmt_ptr, nil) < 0
      LibFF.avformat_close_input(pointerof(afmt_ptr))
      @audio_note = "no audio stream info"
      return
    end
    @a_fmt = afmt_ptr

    dec_ptr = Pointer(Void).null
    idx = LibFF.av_find_best_stream(afmt_ptr, LibFF::AVMEDIA_TYPE_AUDIO,
      -1, -1, pointerof(dec_ptr), 0)
    if idx < 0
      @audio_note = "no audio stream"
      close_audio
      return
    end
    st = afmt_ptr.value.streams[idx]
    par = st.value.codecpar.value
    codec = dec_ptr
    codec = LibFF.avcodec_find_decoder(par.codec_id) if codec.null?
    if codec.null?
      @audio_note = "no decoder for codec #{FF.codec_name(par.codec_id)}"
      close_audio
      return
    end
    cctx = LibFF.avcodec_alloc_context3(codec)
    if LibFF.avcodec_parameters_to_context(cctx, st.value.codecpar) < 0 ||
       LibFF.avcodec_open2(cctx, codec, nil) < 0
      LibFF.avcodec_free_context(pointerof(cctx))
      @audio_note = "audio decoder init failed"
      close_audio
      return
    end
    cctx.value.pkt_timebase = st.value.time_base
    cctx.value.thread_count = 1
    @a_codec_ctx = cctx
    @a_frame = LibFF.av_frame_alloc
    @a_packet = LibFF.av_packet_alloc
    @a_index = st.value.index
    @a_time_base = st.value.time_base
    a_start = st.value.start_time
    if a_start != LibFF::NOPTS && a_start > 0
      @a_start_off = a_start.to_f64 * @a_time_base.num / @a_time_base.den
    else
      @a_start_off = 0.0
    end
    @audio_rate = par.sample_rate
    @audio_channels = {par.ch_nb_channels, 1}.max
    @audio_codec = FF.codec_name(par.codec_id)

    if @audio_rate <= 0 || @audio_channels <= 0
      @audio_note = "bad audio parameters"
      close_audio
      return
    end
    begin
      @ring = MinAudio::PlaybackRing.new(
        @audio_rate, @audio_channels,
        ring_frames: (@audio_rate * AUDIO_RING).to_i32)
      @ring.not_nil!.volume = @volume
    rescue ex : MinAudio::Error
      @audio_note = "audio device: #{ex.message}"
      close_audio
    end
  end

  def play : Nil
    return unless @state == State::Paused || @state == State::Eof
    if @state == State::Eof
      return unless seek(0.0)
    end
    if (ring = @ring)
      # (re)anchor the audio clock at the shown frame, then run the
      # device — consumed counts from this anchor.
      @a_base_pts = @shown_pts
      @a_base_consumed = ring.consumed_frames
      ring.start
    end
    @clock_origin = now_sec - @shown_pts
    @state = State::Playing
  end

  def pause : Nil
    return unless @state == State::Playing
    @shown_pts = position
    # ma_device_stop freezes the callback — the audio clock freezes with
    # it, so resume continues exactly where pause left off.
    @ring.try(&.stop)
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
    close_audio
    zc_disable
    if (f = @zc_frames)
      fp = f
      LibFF.av_buffer_unref(pointerof(fp))
      @zc_frames = nil
      @@hw_pool_ref = nil # never re-attach a dying pool
    end
    hw_graph_reset
    if (sws = @sws)
      LibFF.sws_free_context(sws)
      @sws = nil
    end
    if @sw_frame
      swf = @sw_frame.not_nil!
      LibFF.av_frame_free(pointerof(swf))
      @sw_frame = nil
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
      detach_hw(cctx)
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
    @shown_pts = @display_pts = @next_pts = 0.0
    @frame_count = 0
    @video_eof = false
    # adaptation state: a fresh open re-runs the size search
    @lad.clear
    @li = @search_lo = @search_hi = 0
    @adapt_on = @adapt_locked = false
    @pipe_ms = 0.0
    @probe_n = 0
  end

  private def close_audio : Nil
    if (ring = @ring)
      ring.stop rescue nil
      ring.close
      @ring = nil
    end
    @a_frames.clear
    @a_eof = false
    @a_next_pts = Float64::NAN
    if @a_packet
      pkt = @a_packet.not_nil!
      LibFF.av_packet_free(pointerof(pkt))
      @a_packet = nil
    end
    if @a_frame
      frame = @a_frame.not_nil!
      LibFF.av_frame_free(pointerof(frame))
      @a_frame = nil
    end
    if @a_codec_ctx
      cctx = @a_codec_ctx.not_nil!
      LibFF.avcodec_free_context(pointerof(cctx))
      @a_codec_ctx = nil
    end
    if @a_fmt
      afmt = @a_fmt.not_nil!
      LibFF.avformat_close_input(pointerof(afmt))
      @a_fmt = nil
    end
    @a_index = -1
    @audio_rate = 0
    @audio_channels = 0
    @audio_codec = nil
  end

  # Called every UI frame while a file is open. Audio mode: feed the
  # audio context to its LEAD window, flush the ring, then decode video
  # frames DUE at the audio clock (the device timeline is the truth).
  # Wall-clock mode (no ring): the original pacing, with a resync when
  # decode falls behind.
  # zc import died mid-play (software Vulkan, driver refusal): a
  # same-process reopen crashed in the decoder teardown (heap
  # corruption inside avcodec_free_context — the pool-owning close is
  # not reentrant mid-advance), so the safe fallback is a CLEAN STOP:
  # playback pauses with a status line; the user reopens the file,
  # which now takes the copy-back path (the zc latch is set). On real
  # GPUs imports succeed and this path never runs.
  @zc_reopen : String?

  def advance : Nil
    if (rp = @zc_reopen)
      @zc_reopen = nil
      @error = "zero-copy import failed — reopen the file (copy-back)"
      @state = State::Eof
      @ring.try(&.stop)
      STDERR.puts("video: zc import died — stopped, reopen for copy-back") if ENV["EGUI_VIDEO_DEBUG"]?
      return
    end
    return unless playing?
    if @ring
      feed_audio(audio_clock)
      pump_audio
      # zc: every decode carries a SYNCHRONOUS vaSyncSurface (the map
      # waits for the VPP job). A catch-up burst of 8 stacks 8 GPU syncs
      # into one UI tick — the multi-second freezes. Two per tick keeps
      # the ring fed (60 ticks/s × 2 = 4× realtime headroom) while the
      # syncs spread out; copy-back keeps its 8 (its syncs are cheap).
      budget = @zc ? 2 : 8
      while budget > 0 && !@video_eof &&
            @next_pts <= audio_clock + @frame_dur * 0.6
        break unless decode_next_frame(audio_clock)
        budget -= 1
      end
      mark_eof if @video_eof && audio_drained?
    else
      now = now_sec
      budget = @zc ? 2 : 8
      while budget > 0 && @next_pts <= now - @clock_origin
        break unless decode_next_frame
        budget -= 1
      end
      if budget.zero?
        @clock_origin = now - @shown_pts
      end
      mark_eof if @video_eof
    end
    blit
    debug_tick
  end

  # Every played frame (device-side) drained, backlog empty.
  private def audio_drained? : Bool
    ring = @ring
    return true unless ring
    @a_eof && @a_frames.empty? && ring.buffered_frames.zero?
  end

  # EGUI_VIDEO_DEBUG=1: one stderr line per second — the smoke test's
  # window into decode pacing and A/V sync without screenshot tooling.
  # Called from #advance while playing AND from the app while paused (the
  # clock freezing on pause is exactly what the line should show).
  @@debug_last : Float64 = -1.0
  @@advance_calls : Int32 = 0
  @@decode_calls : Int32 = 0

  def debug_tick : Nil
    @@advance_calls += 1
    return unless ENV["EGUI_VIDEO_DEBUG"]?
    if now_sec - @@debug_last >= 1.0
      @@debug_last = now_sec
      r, g, b, a = {@rgba[0]?, @rgba[1]?, @rgba[2]?, @rgba[3]?}
      ar = avg_channel(0); ag = avg_channel(1); ab = avg_channel(2)
      upd_ms, upd_n = VideoApp.take_update_stats
      astat = if (ring = @ring)
                "clock=%.2f buf=%d/%d backlog=%d wr=%d drop=%d pad=%d" % {
                  audio_clock, ring.buffered_frames, ring.ring_frames,
                  @a_frames.size, @@a_written, @@a_dropped, @@a_padded}
              else
                "no-audio(#{@audio_note || "none"})"
              end
      fd_n = begin
        list = Dir.children("/proc/self/fd").map(&.to_i).sort
        "#{list.size}(max #{list.last})"
      rescue
        "-1"
      end
      last_dup = LibEguiCr.video_last_fd
      dup_open = last_dup >= 0 &&
                 File.symlink?("/proc/self/fd/#{last_dup}") ? 1 : 0
      hwstat = if @hw_transfer
                 size = @lad[@li]? || 0
                 zc = @zc ? "zc " : ""
                 locked = @adapt_locked ? "=" : "~"
                 pool = if @zc
                         pm = @zc_pool_match
                         " pool=#{pm.nil? ? "?" : pm ? "ours" : "THEIRS"}" \
                         " exp=#{@zc_exports.size}"
                       else
                         ""
                       end
                 " hw=#{locked}#{size}/#{width}x#{height}" \
                 "#{zc}#{pool}#{@pipe_ms > 0 ? " pipe=#{@pipe_ms.round(1)}/#{@budget_ms.round(1)}ms" : ""}" \
                 " sync=#{@@zc_sync_n > 0 ? (@@zc_sync_ms / @@zc_sync_n).round(1) : 0}ms/#{@@zc_sync_n} fds=#{fd_n}"
               else
                 ""
               end
      STDERR.printf("video: %-7s pts=%6.2f frames=%-5d fps=%.1f px0=%d,%d,%d,%d avg=%d,%d,%d adv=%d dec=%d blit=%.0fms upd=%.0fms/%d%s a[%s]\n",
        @state.to_s.downcase, @display_pts, @frame_count, @decode_fps,
        r || -1, g || -1, b || -1, a || -1, ar, ag, ab,
        @@advance_calls, @@decode_calls, @@blit_ms, upd_ms, upd_n, hwstat, astat)
      @@advance_calls = 0
      @@decode_calls = 0
      @@blit_ms = 0.0
      @@a_written = 0
      @@a_dropped = 0
      @@a_padded = 0
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
  # decode forward to the target (video and audio — the demuxer serves
  # both, packets route by stream). Returns false on failure.
  def seek(target : Float64) : Bool
    fmt = @fmt
    return false unless fmt
    target = target.clamp(0.0, duration > 0 ? duration : target)
    ts = ((target + @start_off) * 1_000_000).to_i64
    code = LibFF.avformat_seek_file(fmt, -1,
      Int64::MIN, ts, Int64::MAX, LibFF::AVSEEK_FLAG_BACKWARD)
    if code < 0
      @error = "seek failed: #{FF.error_string(code)}"
      return false
    end
    if (cctx = @codec_ctx)
      LibFF.avcodec_flush_buffers(cctx)
    end
    hw_graph_reset # the decoder restarts on a fresh hw frame pool
    @video_eof = false
    seek_audio(target)
    # decode up to the target (or the nearest earlier frame)
    guard = 600
    while guard > 0
      break unless decode_next_frame
      break if @shown_pts + @frame_dur * 0.5 >= target
      guard -= 1
    end
    while (f = @a_frames.first?) && f.pts + f.dur(@audio_rate) <= target - AUDIO_EPS
      @a_frames.shift
      @@a_dropped += f.frames if ENV["EGUI_VIDEO_DEBUG"]?
    end
    blit
    # anchor both clocks at the new position (the audio anchor only
    # matters when the device is running — play() re-anchors otherwise)
    if playing?
      @clock_origin = now_sec - @shown_pts
      if (ring = @ring)
        @a_base_pts = @shown_pts
        @a_base_consumed = ring.consumed_frames
      end
    end
    true
  end

  # Re-position the audio context to `target`: seek its demuxer, flush
  # its decoder, drop the backlog and ring, decode forward to the target
  # (feed_audio's LEAD window reads past it; chunks before the target are
  # dropped by the caller). Failure keeps the old position — audio then
  # resyncs at the next underrun-drop.
  private def seek_audio(target : Float64) : Nil
    afmt = @a_fmt
    return unless afmt && @a_codec_ctx
    ts = ((target + @a_start_off) * 1_000_000).to_i64
    code = LibFF.avformat_seek_file(afmt, -1,
      Int64::MIN, ts, Int64::MAX, LibFF::AVSEEK_FLAG_BACKWARD)
    return if code < 0
    LibFF.avcodec_flush_buffers(@a_codec_ctx.not_nil!)
    @a_eof = false
    @a_next_pts = Float64::NAN
    @a_frames.clear
    @ring.try(&.clear)
    feed_audio(target)
  end

  # --- hardware decode (VAAPI copy-back, the mpv `--hwdec=vaapi-copy`
  # model): the fixed-function decoder offloads H264/HEVC (a 6K camera
  # file decodes at ~4× realtime where software crawls at 0.5×); the
  # decoded surface is copied back to a CPU frame (NV12) and sws_scale
  # converts it as before. Everything degrades to software when VAAPI
  # is missing (no render node / headless / EGUI_VIDEO_HW=0).

  # AVBufferRef* of the VAAPI device (nil = software decode)
  @hw_device : UInt8*? = nil
  # transfer target for copy-back frames (freed in #close)
  @sw_frame : LibFF::AVFrame*? = nil
  # GPU scale pipeline (scale_vaapi → hwdownload): decoding stays at
  # native res on the fixed-function unit, the frame DOWNSCALES on the
  # GPU too, and only the small NV12 copy crosses back to the CPU — a
  # full-res 6K download crawls (~0.2× realtime), a 1080p one is free.
  @hw_transfer : Bool = false
  @filter_graph : Void*? = nil
  @buffersrc : Void*? = nil
  @buffersink : Void*? = nil

  # --- adaptive output scale ----------------------------------------------
  # Budget: the hw pipeline (VPP scale + hwdownload + sws) must sustain
  # the video's native fps ×1.5, measured per decoded frame (EMA over a
  # 6-frame window per candidate). Binary search over the ladder of
  # long-side sizes — index 0 is NATIVE (no scaling): small files never
  # scale at all. After the search locks, runtime drift (compositor
  # load, thermal) steps DOWN one size at a time — quality degrades,
  # playback never stalls. EGUI_VIDEO_HW_SCALE=<n> pins a size and
  # disables adaptation.
  @lad : Array(Int32) = [] of Int32
  @li : Int32 = 0
  @search_lo : Int32 = 0
  @search_hi : Int32 = 0
  @graph_target : {Int32, Int32}? = nil
  @adapt_on : Bool = false
  @adapt_locked : Bool = false
  @budget_ms : Float64 = 0.0
  @pipe_ms : Float64 = 0.0
  @probe_n : Int32 = 0
  @skip_sample : Bool = false

  # get_format callback: pick the VAAPI pix fmt when the decoder offers
  # it, else the first software format (a decoder without a VAAPI hw
  # config simply never offers it). Class-level: a C callback cannot
  # capture, and the pix fmt value is runtime (av_get_pix_fmt).
  @@hw_pix_fmt : Int32 = -1
  # OUR fixed pool, re-attached BY this callback: ffmpeg 7.1's
  # ff_get_format starts every iteration with ff_hwaccel_uninit, which
  # unconditionally unrefs avctx->hw_frames_ctx — a pool attached before
  # open2 is stripped BEFORE the hwaccel init asks for it, and vaapi
  # falls back to its own DYNAMIC pool (a fresh VA surface per frame).
  # The callback runs between the uninit and hwaccel_init — the only
  # window where the re-attach sticks.
  @@hw_pool_ref : Pointer(UInt8)? = nil

  HW_GET_FORMAT = ->(ctx : LibFF::AVCodecContext*, fmts : Int32*) : Int32 do
    i = 0
    while (f = fmts[i]) != -1 # AV_PIX_FMT_NONE-terminated list
      if f == @@hw_pix_fmt
        if (ref = @@hw_pool_ref) && ctx.value.hw_frames_ctx.null?
          ctx.value.hw_frames_ctx = LibFF.av_buffer_ref(ref)
        end
        return f
      end
      i += 1
    end
    fmts[0]
  end

  # Attach the VAAPI device + get_format to a fresh codec context.
  # True = attached (copy-back transfer engages), false = software.
  private def setup_hw(cctx : LibFF::AVCodecContext*) : Bool
    return false if ENV["EGUI_VIDEO_HW"]? == "0"
    dev_path = ENV["EGUI_VIDEO_HW_DEVICE"]? || "/dev/dri/renderD128"
    return false unless File.exists?(dev_path)
    hwfmt = LibFF.av_get_pix_fmt("vaapi".to_unsafe)
    return false if hwfmt < 0
    dev = Pointer(UInt8).null
    code = LibFF.av_hwdevice_ctx_create(pointerof(dev),
      LibFF::AV_HWDEVICE_TYPE_VAAPI, dev_path.to_unsafe, nil, 0)
    return false if code < 0 || dev.null?
    @@hw_pix_fmt = hwfmt
    @hw_device = dev
    @hw_transfer = true
    cctx.value.hw_device_ctx = dev
    cctx.value.get_format = HW_GET_FORMAT
    STDERR.puts("video: hw decode via VAAPI") if ENV["EGUI_VIDEO_DEBUG"]?
    true
  end

  # Ask the decoder itself what hw frames it needs: a throwaway
  # demuxer+decoder on the same path (sharing our VA device) decodes
  # ONE frame and we read ITS hw_frames_ctx. codecpar carries no bit
  # depth (a 10-bit HEVC in MOV probes as format=-1) — a wrong
  # sw_format guess makes ffmpeg silently discard our fixed pool and
  # run its own DYNAMIC one (fresh VA surface per frame: the
  # export/import churn that killed big files). {sw_format, w, h}?
  private def probe_hw_params(path : String, codec : Void*) : {Int32, Int32, Int32}?
    pf = Pointer(LibFF::AVFormatContext).null
    return nil if LibFF.avformat_open_input(pointerof(pf),
        path.to_unsafe, nil, nil) < 0 || pf.null?
    pidx = LibFF.av_find_best_stream(pf, LibFF::AVMEDIA_TYPE_VIDEO,
        -1, -1, nil, 0)
    result = nil
    if pidx >= 0 && !(pst = pf.value.streams[pidx]).null? &&
       !(ppar = pst.value.codecpar).null?
      pcctx = LibFF.avcodec_alloc_context3(codec)
      if pcctx && LibFF.avcodec_parameters_to_context(pcctx, ppar) >= 0
        pcctx.value.hw_device_ctx = LibFF.av_buffer_ref(@hw_device.not_nil!)
        pcctx.value.get_format = HW_GET_FORMAT
        if LibFF.avcodec_open2(pcctx, codec, nil) >= 0
          ppkt = LibFF.av_packet_alloc
          pfrm = LibFF.av_frame_alloc
          while ppkt && pfrm
            code = LibFF.av_read_frame(pf, ppkt)
            break if code < 0 # EOF included — nothing decodable
            if ppkt.value.stream_index == pidx
              LibFF.avcodec_send_packet(pcctx, ppkt)
              LibFF.av_packet_unref(ppkt)
              loop do
                code = LibFF.avcodec_receive_frame(pcctx, pfrm)
                break if code == LibFF::AVERROR_EAGAIN || code < 0
                if pfrm.value.format == @@hw_pix_fmt &&
                   !pfrm.value.hw_frames_ctx.null? &&
                   (fctx = LibVideoPool.ref_data(pfrm.value.hw_frames_ctx))
                  fc = fctx.as(LibFF::AVHWFramesContext*)
                  if fc.value.sw_format > 0 && fc.value.width > 0
                    result = {fc.value.sw_format, fc.value.width,
                              fc.value.height}
                  end
                end
                LibFF.av_frame_unref(pfrm)
                break if result
              end
              break if result
            else
              LibFF.av_packet_unref(ppkt)
            end
          end
          LibFF.av_packet_free(pointerof(ppkt)) if ppkt
          LibFF.av_frame_free(pointerof(pfrm)) if pfrm
        end
        LibFF.avcodec_free_context(pointerof(pcctx))
      end
    end
    pf2 = pf
    LibFF.avformat_close_input(pointerof(pf2))
    if result && ENV["EGUI_VIDEO_DEBUG"]?
      STDERR.puts("video: zc pool probed sw=#{result[0]} #{result[1]}x#{result[2]}")
    end
    result
  end

  # Drop the hw attachment (open2-with-hw failed fallback, close).
  private def detach_hw(cctx : LibFF::AVCodecContext*) : Nil
    @hw_transfer = false
    cctx.value.hw_device_ctx = Pointer(UInt8).null
    if (dev = @hw_device)
      dev_ptr = dev
      LibFF.av_buffer_unref(pointerof(dev_ptr))
      @hw_device = nil
    end
  end

  # Build the scale_vaapi graph around the FIRST decoded hw frame (its
  # hw_frames_ctx is what scale_vaapi needs). True = graph is live.
  # Only DOWNSCALING engages: small frames transfer full-res directly.
  private def hw_graph_ensure(first : LibFF::AVFrame*) : Bool
    return true if @buffersrc
    src_w = first.value.width
    src_h = first.value.height
    # Adaptive output scale: candidate long-side sizes, largest first
    # (index 0 = native — no scaling at all). The first hw frame seeds
    # the ladder; EGUI_VIDEO_HW_SCALE pins one size and disables
    # adaptation.
    native = {src_w, src_h}.max
    if @lad.empty?
      if @zc
        # Zero-copy pays no CPU tax — quality stays. One fixed slot
        # (native capped at 2560 keeps VPP cost sane on 6K+ sources);
        # no probing, no drift: the adaptation ladder exists to protect
        # the copy-back pipeline, not the GPU one.
        @lad = [{native, 2560}.min]
        @adapt_on = false
        @adapt_locked = true
      else
        @lad = [native, 3840, 2560, 1920, 1600, 1280, 1024, 854, 640]
          .select { |s| s < native }.uniq.sort.reverse.unshift(native)
      end
      @budget_ms = 1000.0 * @frame_dur / 1.5
      @search_lo = 0
      @search_hi = @lad.size - 1
      @li = 0
      @adapt_on = true
      if (pin = ENV["EGUI_VIDEO_HW_SCALE"]?)
        pin_i = pin.to_i? || 1920
        best = @lad.index { |s| s <= pin_i } || @lad.size - 1
        @li = best
        @adapt_on = false
        @adapt_locked = true
      end
    end
    scale = @lad[@li]? || native
    return false if scale >= native && !@zc
    if src_w >= src_h
      tw = scale
      th = {src_h * scale // src_w, 2}.max & ~1
    else
      th = scale
      tw = {src_w * scale // src_h, 2}.max & ~1
    end
    return true if @graph_target == {tw, th} && @buffersrc
    hw_graph_reset
    @graph_target = {tw, th}

    graph = LibFF.avfilter_graph_alloc
    src = LibFF.avfilter_graph_alloc_filter(graph,
      LibFF.avfilter_get_by_name("buffer"), "src")
    sink = LibFF.avfilter_graph_alloc_filter(graph,
      LibFF.avfilter_get_by_name("buffersink"), "sink")
    if graph.null? || src.null? || sink.null?
      STDERR.puts("video: hw graph: alloc failed graph=#{graph.null?} src=#{src.null?} sink=#{sink.null?}") if ENV["EGUI_VIDEO_DEBUG"]?
      LibFF.avfilter_graph_free(pointerof(graph)) unless graph.null?
      return false
    end
    par = LibFF.av_buffersrc_parameters_alloc
    par.value.format = first.value.format
    par.value.width = src_w
    par.value.height = src_h
    par.value.time_base = @time_base
    par.value.hw_frames_ctx = first.value.hw_frames_ctx
    LibFF.av_buffersrc_parameters_set(src, par)
    LibFF.av_free(par)
    # init with NULL args: the parameters above ARE the config
    if LibFF.avfilter_init_str(src, nil_wire) < 0 ||
       LibFF.avfilter_init_str(sink, nil_wire) < 0
      STDERR.puts("video: hw graph: init_str failed") if ENV["EGUI_VIDEO_DEBUG"]?
      LibFF.avfilter_graph_free(pointerof(graph))
      return false
    end

    outputs = LibFF.avfilter_inout_alloc
    inputs = LibFF.avfilter_inout_alloc
    outputs.value.name = LibFF.av_strdup("in")
    outputs.value.filter_ctx = src
    inputs.value.name = LibFF.av_strdup("out")
    inputs.value.filter_ctx = sink
    chain = @zc ? "scale_vaapi=#{tw}:#{th},format=vaapi" # anchor the sink (hw frames stay on the GPU)
                # NO format=nv12: 10-bit full-range quantized on a
                # LIMITED ladder comes out washed (twinshot mean 93 vs
                # 0.7 through P010 + sws).
                : "scale_vaapi=#{tw}:#{th},hwdownload,format=p010le"
    code = LibFF.avfilter_graph_parse_ptr(graph, chain,
      pointerof(inputs), pointerof(outputs), nil)
    LibFF.avfilter_inout_free(pointerof(inputs))
    LibFF.avfilter_inout_free(pointerof(outputs))
    if code < 0
      STDERR.puts("video: hw graph: parse failed: #{FF.error_string(code)}") if ENV["EGUI_VIDEO_DEBUG"]?
      LibFF.avfilter_graph_free(pointerof(graph))
      return false
    end
    code = LibFF.avfilter_graph_config(graph, nil)
    if code < 0
      STDERR.puts("video: hw graph: config failed: #{FF.error_string(code)}") if ENV["EGUI_VIDEO_DEBUG"]?
      LibFF.avfilter_graph_free(pointerof(graph))
      return false
    end
    @filter_graph = graph
    @buffersrc = src
    @buffersink = sink
    STDERR.puts("video: hw scale_vaapi #{src_w}x#{src_h}→#{tw}x#{th}") if ENV["EGUI_VIDEO_DEBUG"]?
    true
  end

  private def nil_wire : UInt8*
    Pointer(UInt8).null
  end

  # One decoded hw frame's pipeline cost feeds the adaptation. Windows
  # of 6 frames per candidate; binary search between @search_lo/hi
  # finds the LARGEST size whose EMA fits @budget_ms.
  private def adapt_tick(ms : Float64) : Nil
    return unless @adapt_on
    # first sample after a (re)build carries the graph-config cost —
    # it says nothing about steady-state pipeline speed
    if @skip_sample
      @skip_sample = false
      return
    end
    @pipe_ms = @pipe_ms.zero? ? ms : 0.7 * @pipe_ms + 0.3 * ms
    @probe_n += 1
    # window: 6 frames, or an instant fail when a candidate blows 3×
    # the budget (native 6K transfer is ~150 ms/frame)
    blown = !@adapt_locked && @pipe_ms > @budget_ms * 3.0
    return if @probe_n < 6 && !blown
    @probe_n = 0
    pass = !blown && @pipe_ms <= @budget_ms
    if @adapt_locked
      # runtime drift — only ever DOWN (quality degrades, never stalls)
      if !pass && @li < @lad.size - 1
        old = @pipe_ms
        @li += 1
        hw_graph_reset
        @pipe_ms = 0.0
        STDERR.puts("video: hw scale → #{@lad[@li]} " \
                    "(drift #{old.round(1)}ms > budget #{@budget_ms.round(1)}ms)") if ENV["EGUI_VIDEO_DEBUG"]?
      end
      return
    end
    if pass
      @search_hi = @li
    else
      @search_lo = @li + 1
    end
    if @search_lo >= @search_hi
      idx = {@search_hi, @lad.size - 1}.min
      @adapt_locked = true
      @li = idx
      @pipe_ms = 0.0
      @probe_n = 0
      STDERR.puts("video: hw scale locked at #{@lad[idx]} " \
                  "(budget #{@budget_ms.round(1)}ms)") if ENV["EGUI_VIDEO_DEBUG"]?
    else
      @li = (@search_lo + @search_hi) // 2
      hw_graph_reset
      @pipe_ms = 0.0
      STDERR.puts("video: hw scale probing #{@lad[@li]}") if ENV["EGUI_VIDEO_DEBUG"]?
    end
  end

  # Drop the scale graph (seek flush / adaptation step / close): the
  # decoder restarts on a fresh hw frame pool, the graph must be rebuilt
  # from the next one — at the CURRENT ladder size (@graph_target
  # cleared so hw_graph_ensure rebuilds).
  private def hw_graph_reset : Nil
    @graph_target = nil
    @probe_n = 0
    @skip_sample = true
    if (g = @filter_graph)
      gp = g
      LibFF.avfilter_graph_free(pointerof(gp))
      @filter_graph = nil
      @buffersrc = nil
      @buffersink = nil
    end
  end

  # VAAPI copy-back: push the hw surface through the scale graph and
  # take the downscaled NV12 frame back to the CPU. Without the graph
  # (small frames / graph failure) a full-res transfer runs instead.
  # Software decode passes the frame through untouched. Nil on failure.
  # --- zero-copy path (Vulkan backend) ----------------------------------
  # hw decode → scale_vaapi (GPU) → av_hwframe_map → dmabuf descriptor →
  # egui_cr_video_frame: the render thread imports the planes as VkImages
  # and draws through the video pipeline. No pixels cross to the CPU —
  # the copy-back pipeline stays as the fallback (GL backends, import
  # failures).
  @zc : Bool = false
  @video_id : UInt32 = 0_u32
  getter video_texture_id : UInt64 = 0_u64
  @zc_frames : UInt8*? = nil      # OUR fixed VA surface pool
  @zc_holds : Array(LibFF::AVFrame*)? # display hold ring (see #zc_hold_frame)
  # export-once-per-surface (the gstvaallocator model): the fixed pool
  # cycles ~20 surfaces, so ~20 exports TOTAL instead of one per frame —
  # the per-frame map leaked one dmabuf fd per frame inside ffmpeg 7.1's
  # VA→DRM export, and the R-side dup of a per-frame fd leaked another
  # from OUR side (both died with this cache).
  # Key: the AVFrame's pool-buffer identity (buf[0] pointer value). The
  # cached fd stays valid while WE hold it; the surface returns to the
  # decode pool, and when the pool recycles it the SAME dmabuf carries
  # the new frame (the R-side VkImage reads fresh content by inode
  # identity). The per-frame decode-write barrier is an explicit
  # vaSyncSurface now — the map ran it only as a side effect.
  @zc_exports = {} of UInt64 => ZcExport
  # per-frame check: does the decoded frame come from OUR fixed pool?
  @zc_pool_match : Bool? = nil
  # latch: once an import pipeline died in this process, never retry zc
  # (prevents reopen loops on drivers without dmabuf import)
  @@zc_dead = false
  @@dbg_n : Int32 = 0
  @@zc_sync_ms : Float64 = 0.0 # vaSyncSurface time (diagnostics)
  @@zc_sync_n : Int32 = 0

  AV_HWDEVICE_TYPE_DRM = 8

  # CPU-side colorimetry (bt709/601 × full/limited): rows of the YUV→RGB
  # matrix (the limited ladders carry their 255/219 scale in the rows;
  # `range` carries the offsets only — the shader does raw*scale+bias).
  private def compute_colorimetry(cctx : LibFF::AVCodecContext*, tenbit : Bool) : Nil
    full = cctx.value.color_range == 2
    bt709 = cctx.value.colorspace != 5 # 5 = bt470bg (601); 0/unspec → 709 (HD default)
    rows = if bt709 && full
            {1.0, 0.0, 1.5748, 1.0, -0.1873, -0.4681, 1.0, 1.8556, 0.0}
          elsif bt709
            {1.1644, 0.0, 1.7927, 1.1644, -0.2132, -0.5329, 1.1644, 2.1124, 0.0}
          elsif full
            {1.0, 0.0, 1.402, 1.0, -0.3441, -0.7141, 1.0, 1.772, 0.0}
          else
            {1.1644, 0.0, 1.596, 1.1644, -0.3918, -0.813, 1.1644, 2.0172, 0.0}
          end
    # normalized-sample offsets: 10-bit planes normalize v10/1023,
    # 8-bit v/255. Chroma is ALWAYS bipolar around its mid (512/1023,
    # 128/255) — full vs limited only moves the LUMA ladder (64..940 /
    # 0..1023); forgetting the chroma center stains everything magenta.
    y_off = full ? 0.0 : (tenbit ? 64.0 / 1023.0 : 16.0 / 255.0)
    c_off = tenbit ? 512.0 / 1023.0 : 128.0 / 255.0
    # std140 mat3: 3 columns × vec4 slots (float c*4+r), zero-padded —
    # the shader reads a 12-float block, not 9 packed
    @zc_cmat = StaticArray(Float32, 12).new(0.0f32)
    3.times do |r|
      3.times do |c|
        @zc_cmat.not_nil![c * 4 + r] = rows[r * 3 + c].to_f32
      end
    end
    @zc_range = StaticArray(Float32, 4).new(0.0f32)
    @zc_range.not_nil![0] = 1.0f32
    @zc_range.not_nil![1] = y_off.to_f32 * -1.0f32
    @zc_range.not_nil![2] = 1.0f32
    @zc_range.not_nil![3] = c_off.to_f32 * -1.0f32
  end

  @zc_cmat : StaticArray(Float32, 12)?
  @zc_range : StaticArray(Float32, 4)?

  # Display-hold backpressure (the gstva sink model): keep the last
  # ZC_HOLD_DEPTH frames' pool checkouts alive, releasing the oldest as
  # each new frame is queued. Releasing the surface immediately let the
  # decoder overwrite it (a FUTURE frame) while the render thread had
  # not sampled the current import yet — on-screen that read as torn
  # half-frames / a "second video" flickering a few times a second. The
  # render thread can lag the produce thread by a couple of frames (the
  # texop mailbox coalesces to the newest op), so one held frame was not
  # enough; four covers the lag with pool headroom to spare.
  ZC_HOLD_DEPTH = 4
  @zc_holds : Array(LibFF::AVFrame*)?
  @zc_hold_i : Int32 = 0

  private def zc_hold_frame(frame : LibFF::AVFrame*) : Nil
    holds = (@zc_holds ||=
             Array.new(ZC_HOLD_DEPTH) { LibFF.av_frame_alloc })
    slot = holds[@zc_hold_i % ZC_HOLD_DEPTH]
    @zc_hold_i += 1
    LibFF.av_frame_unref(slot)      # release the frame DEPTH frames ago
    LibFF.av_frame_ref(slot, frame) # pin this one
    LibFF.av_frame_unref(frame)
  end

  # One hw frame → dmabuf op. False = failure (caller falls back).
  private def zc_frame(frame : LibFF::AVFrame*) : Bool
    if LibEguiCr.video_failed != 0 && !@zc_reopen
      # import pipeline dead — the graph cannot run over OUR pool
      # (scale_vaapi: invalid VADisplay), so a clean reopen in
      # copy-back mode is the only working fallback
      @zc_reopen = @path
      zc_disable_quiet
      return false
    end

    # pts BEFORE any unref — the frame dies on both paths below
    pts0 = frame.value.pts
    pts0 = frame.value.best_effort_timestamp if pts0 == LibFF::NOPTS || pts0 < 0
    # the pool slot identity AND the vaSyncSurface argument: the
    # VASurfaceID in data[3] (buf[0] is NOT a stable key — the pool
    # wraps each checkout in a fresh AVBufferRef, probed on ffmpeg 7.1)
    surface = frame.value.data[3].address
    # pool identity: a frame's hw_frames_ctx is a per-checkout
    # AVBufferRef WRAPPER — compare the ->data both refs point at (raw
    # AVHWFramesContext field reads through the ref are garbage)
    frame_ctx = LibVideoPool.ref_data(frame.value.hw_frames_ctx)
    ours_ctx = LibVideoPool.ref_data(@zc_frames.not_nil!)
    @zc_pool_match = frame_ctx == ours_ctx
    if ENV["EGUI_VIDEO_DEBUG"]? && (@@dbg_n += 1) <= 4
      STDERR.printf("[zc] pool=%s frame_ctx=%x ours=%x | sid=%x exports=%d\n",
        @zc_pool_match ? "OURS" : "THEIRS", frame_ctx.address,
        ours_ctx.address, surface, @zc_exports.size)
    end

    # decode-write barrier FIRST: the decoder's job for THIS surface
    # must finish before the render thread samples the import. The old
    # path got this implicitly from av_hwframe_map; with export-once
    # the map runs too rarely to order anything.
    t_sync = Time.instant
    if LibVideoPool.sync_surface(@hw_device.not_nil!, surface.to_u32) != 0
      @error = "zc: vaSyncSurface failed"
      LibFF.av_frame_unref(frame)
      return false
    end
    @@zc_sync_ms += (Time.instant - t_sync).total_milliseconds
    @@zc_sync_n += 1

    if exp = @zc_exports[surface]?
      # known surface: no map, no export — the cached fd pins the same
      # dmabuf, whose inode the R side already imported. The shim's fd
      # contract is OWNED (its op closes or consumes it), so the cache's
      # long-lived fd never crosses the boundary — each frame hands the
      # shim a fresh dup of it (the gstvaallocator model: the pool keeps
      # its dmabufs forever, consumers take their own references).
      zc_hold_frame(frame)
      fd = LibFF.dup_fd(exp.fd)
      size_i = exp.size
      w = exp.w
      h = exp.h
      pitch_y = exp.pitch_y
      pitch_uv = exp.pitch_uv
      off_y = exp.off_y
      off_uv = exp.off_uv
      modifier = exp.modifier
      fc_y = exp.fc_y
      fc_uv = exp.fc_uv
    else
      # first sight of this pool surface: export ONCE via a direct
      # vaExportSurfaceHandle (backend/video_pool.c) and keep the fd for
      # the surface's whole life. This REPLACES ffmpeg's derived-DRM-ctx
      # + av_hwframe_map path — that one checked out an EXTRA VA surface
      # from our pool per map (the derived ctx's get_buffer pulls its
      # own), bloating the decoder's working set from ~3 to ~25 surfaces
      # and starving the pool (repro: tools/zc_probe.c pin=3 vs pin=1);
      # it also leaked one fd per map inside ffmpeg 7.1.
      xfer = StaticArray(Int64, 12).new(0_i64)
      if LibVideoPool.export_surface(@hw_device.not_nil!, surface.to_u32,
                                     xfer.to_unsafe) != 0
        @error = "zc: export sid #{surface}"
        LibFF.av_frame_unref(frame)
        return false
      end
      zc_hold_frame(frame)

      keep_fd = xfer[0].to_i32     # the cache's fd — lives forever
      fd = LibFF.dup_fd(keep_fd)  # the op's fd — owned by the shim
      size_i = xfer[1].to_i32
      w = xfer[2].to_i32
      h = xfer[3].to_i32
      pitch_y = xfer[4].to_i32
      pitch_uv = xfer[5].to_i32
      off_y = xfer[6].to_i32
      off_uv = xfer[7].to_i32
      modifier = xfer[8].to_u64!
      fc_y = xfer[10].to_u32!
      fc_uv = xfer[11].to_u32!

      @zc_exports[surface] = ZcExport.new(keep_fd, size_i, w, h,
        pitch_y, pitch_uv, off_y, off_uv, modifier, fc_y, fc_uv)
    end

    compute_colorimetry(@codec_ctx.not_nil!,
      tenbit: fc_y == 0x20363152u32) # 'R16 '
    LibEguiCr.video_frame(@video_id, fd, size_i, w, h,
      pitch_y, pitch_uv, off_y, off_uv, modifier,
      fc_y, fc_uv,
      @zc_cmat.not_nil!.to_unsafe, @zc_range.not_nil!.to_unsafe)

    @shown_pts = pts0 != LibFF::NOPTS && pts0 >= 0 ? pts_to_seconds(pts0) : @shown_pts + @frame_dur
    @display_pts = @shown_pts
    @next_pts = @shown_pts + @frame_dur
    @width = w
    @height = h
    @frame_count += 1
    @fps_frames += 1
    if @fps_frames == 1
      @fps_wall = now_sec
    elsif (dt = now_sec - @fps_wall) >= 1.0
      @decode_fps = @fps_frames / dt
      @fps_frames = 0
    end
    true
  end

  # Release zero-copy resources WITHOUT the copy-back ladder surgery —
  # used by the reopen fallback (close/open rebuilds everything).
  private def zc_disable_quiet : Nil
    @zc = false
    @video_texture_id = 0_u64
    unless @video_id.zero?
      LibEguiCr.video_destroy(@video_id)
      @video_id = 0_u32
    end
    if (holds = @zc_holds)
      holds.each { |h| hp = h; LibFF.av_frame_free(pointerof(hp)) }
      @zc_holds = nil
      @zc_hold_i = 0
    end
    # the export cache pins one fd per pool surface — release them (the
    # R side holds its own refs where it still samples the import)
    @zc_exports.each_value { |e| LibC.close(e.fd) }
    @zc_exports.clear
  end

  # Drop the zero-copy path mid-play: back to copy-back (GL / import
  # failure). The scale graph rebuilds with hwdownload on the next frame.
  private def zc_disable : Nil
    return unless @zc
    @@zc_dead = true
    zc_disable_quiet
    @video_texture_id = 0_u64
    # Back to copy-back: its CPU cost is resolution-sensitive, so the
    # adaptive ladder wakes up again (staying at the zc fixed size
    # would stall the produce thread — the copy-back pipeline cannot
    # sustain it).
    native = {@width, @height}.max
    @lad = [native, 3840, 2560, 1920, 1600, 1280, 1024, 854, 640]
      .select { |s| s <= native }.uniq.sort.reverse
    @search_lo = 0
    @search_hi = @lad.size - 1
    cur = {(@lad[0] == native ? native : native), @lad[@li]? || native}.min
    @li = @lad.index { |s| s <= (@lad[@li]? || native) } ||
          {@lad.size // 2, @lad.size - 1}.min
    @adapt_on = true
    @adapt_locked = false
    @pipe_ms = 0.0
    @probe_n = 0
    hw_graph_reset
    @sws = nil
  end

  private def maybe_transfer(frame : LibFF::AVFrame*) : LibFF::AVFrame*?
    return frame unless @hw_transfer
    if frame.value.format == @@hw_pix_fmt && hw_graph_ensure(frame) &&
       (src = @buffersrc) && (sink = @buffersink)
      code = LibFF.av_buffersrc_add_frame_flags(src, frame, 0)
      LibFF.av_frame_unref(frame) # surface back to the decoder's pool
      return nil if code < 0
      dst = (@sw_frame ||= LibFF.av_frame_alloc)
      LibFF.av_frame_unref(dst)
      code = LibFF.av_buffersink_get_frame(sink, dst)
      @error = "hw frame pipeline failed: #{FF.error_string(code)}" if code < 0
      return nil if code < 0
      # a graph built for zero-copy (vaapi sink) has no CPU pixels —
      # never hand it to the conversion path
      return nil if dst.value.format == @@hw_pix_fmt
      return dst
    end
    if frame.value.format == @@hw_pix_fmt
      dst = (@sw_frame ||= LibFF.av_frame_alloc)
      LibFF.av_frame_unref(dst)
      code = LibFF.av_hwframe_transfer_data(dst, frame, 0)
      if code < 0
        @error = "hw frame transfer failed: #{FF.error_string(code)}"
        LibFF.av_frame_unref(frame)
        return nil
      end
      LibFF.av_frame_unref(frame) # surface back to the decoder's pool
      return dst
    end
    # A hw frame with no working transfer path must die HERE — feeding
    # it onward makes sws_get_context return NULL and sws_scale(NULL)
    # segfault (the seek crash: "vaapi is not supported as input")
    return nil if frame.value.format == @@hw_pix_fmt
    frame
  end

  # --- internals ----------------------------------------------------------

  # Land in the Eof state: freeze at the end position (Play restarts
  # from the beginning from there).
  private def mark_eof : Nil
    return if @state == State::Eof
    @state = State::Eof
    @shown_pts = duration > 0 ? duration : @shown_pts
    @ring.try(&.stop) # clock freezes with the last played frame
    STDERR.puts("video: eof") if ENV["EGUI_VIDEO_DEBUG"]?
  end

  private def pts_to_seconds(pts : Int64) : Float64
    pts.to_f64 * @time_base.num / @time_base.den - @start_off
  end

  private def a_pts_to_seconds(pts : Int64) : Float64
    pts.to_f64 * @a_time_base.num / @a_time_base.den - @a_start_off
  end

  # Decode the next video frame, converting it to RGBA when it is DUE at
  # `clock` (nil = always — open/seek paths); frames arriving early keep
  # the displayed pixels untouched. Returns false at EOF or error.
  private def decode_next_frame(clock : Float64? = nil) : Bool
    @@decode_calls += 1
    fmt = @fmt.not_nil!
    cctx = @codec_ctx.not_nil!
    frame = @frame.not_nil!
    pkt = @packet.not_nil!

    loop do
      code = LibFF.avcodec_receive_frame(cctx, frame)
      if code == 0
        t0 = Time.instant
        if @zc && @hw_transfer && frame.value.format == @@hw_pix_fmt
          ok = zc_frame(frame)
          if !ok && LibEguiCr.video_failed != 0
            zc_disable
            return false
          end
          adapt_tick((Time.instant - t0).total_milliseconds) if @hw_transfer
          return ok
        end
        ok = false
        if (cpu = maybe_transfer(frame))
          convert_frame(cpu, clock)
          ok = true
        end
        if @hw_transfer
          adapt_tick((Time.instant - t0).total_milliseconds)
        end
        return ok
      end
      if code == LibFF::AVERROR_EOF
        @video_eof = true
        return false
      end
      if code != LibFF::AVERROR_EAGAIN
        @error = "decode failed: #{FF.error_string(code)}"
        return false
      end

      # decoder is hungry: feed it the next video packet (audio demuxes
      # through its own context — audio packets here are not ours)
      loop do
        code = LibFF.av_read_frame(fmt, pkt)
        if code == LibFF::AVERROR_EOF
          # flush the video decoder, then EOF
          LibFF.avcodec_send_packet(cctx, nil)
          drain = LibFF.avcodec_receive_frame(cctx, frame)
          if drain == 0
            if (cpu = maybe_transfer(frame))
              convert_frame(cpu, clock)
              return true
            end
            return false
          end
          @video_eof = true
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
        else
          LibFF.av_packet_unref(pkt) # not ours: keep reading
        end
      end
    end
  end

  # --- audio pipeline ------------------------------------------------------

  # Pull packets from the AUDIO context until the decoder frontier covers
  # its LEAD window (or its demuxer hits EOF, which flushes the decoder).
  # The audio context is independent — video pacing never starves it and
  # vice versa.
  private def feed_audio(clock : Float64) : Nil
    afmt = @a_fmt
    return unless afmt && @a_codec_ctx
    pkt = @a_packet.not_nil!
    guard = 100
    while guard > 0
      break if @a_eof
      break unless @a_next_pts.nan? || @a_next_pts < clock + AUDIO_LEAD
      code = LibFF.av_read_frame(afmt, pkt)
      if code == LibFF::AVERROR_EOF
        flush_audio_decoder
        break
      end
      break if code < 0
      dispatch_audio_packet(pkt) if pkt.value.stream_index == @a_index
      LibFF.av_packet_unref(pkt) # the audio context serves audio only
      guard -= 1
    end
  end

  # Open-time prebuffer: decode AUDIO_LEAD of PCM past `target`, then fill
  # the ring before the device runs.
  private def prebuffer_audio(target : Float64) : Nil
    return unless @ring && @a_codec_ctx
    feed_audio(target)
    pump_audio_prestart(target)
  end

  # Feed the ring before the device runs: the clock is the anchor pts.
  private def pump_audio_prestart(target : Float64) : Nil
    ring = @ring
    return unless ring
    # drop stale, flush the backlog
    while (f = @a_frames.first?) && f.pts + f.dur(@audio_rate) <= target - AUDIO_EPS
      @a_frames.shift
    end
    if (f = @a_frames.first?) && f.pts > target + AUDIO_EPS
      pad = ((f.pts - target) * @audio_rate).to_i32
      if pad > 0
        @a_frames.unshift(AudioChunk.new(target, Bytes.new(pad * @audio_channels * 4), pad))
        @@a_padded += pad if ENV["EGUI_VIDEO_DEBUG"]?
      end
    end
    flush_audio_ring
  end

  # One audio packet → decoder → backlog chunks. Keeps the decoder
  # drained (send EAGAIN would stall the demux loop otherwise).
  private def dispatch_audio_packet(pkt : LibFF::AVPacket*) : Nil
    actx = @a_codec_ctx
    return unless actx
    send = LibFF.avcodec_send_packet(actx, pkt)
    if send == LibFF::AVERROR_EAGAIN
      receive_audio_frames(false) # drain fully, then retry once
      send = LibFF.avcodec_send_packet(actx, pkt)
    end
    receive_audio_frames(true)
  end

  # Send end-of-stream to the audio decoder and collect what remains.
  private def flush_audio_decoder : Nil
    actx = @a_codec_ctx
    return unless actx
    LibFF.avcodec_send_packet(actx, nil)
    receive_audio_frames(false)
    @a_eof = true
  end

  # Pull decoded audio frames into the backlog. `paced` limits the run to
  # AUDIO_LEAD ahead of the clock (the steady state); unpaced drains
  # whatever the decoder holds (flush / send-EAGAIN recovery).
  private def receive_audio_frames(paced : Bool) : Nil
    actx = @a_codec_ctx
    frame = @a_frame
    return unless actx && frame
    loop do
      if paced
        clock = @ring ? audio_clock : @shown_pts
        break unless @a_next_pts.nan? || @a_next_pts < clock + AUDIO_LEAD
      end
      code = LibFF.avcodec_receive_frame(actx, frame)
      break if code == LibFF::AVERROR_EAGAIN || code == LibFF::AVERROR_EOF
      if code < 0
        @audio_note = "audio decode failed: #{FF.error_string(code)}"
        break
      end
      append_audio_frame(frame)
      LibFF.av_frame_unref(frame)
    end
  end

  # Convert one decoded audio frame to an f32-interleaved chunk, minding
  # the timeline: gaps pad with silence, stale frames drop (underrun
  # recovery — the clock already played past them).
  private def append_audio_frame(frame : LibFF::AVFrame*) : Nil
    n = frame.value.nb_samples
    return if n <= 0
    pts = frame.value.pts
    if pts != LibFF::NOPTS && pts >= 0
      pts_sec = a_pts_to_seconds(pts)
    else
      pts_sec = @a_next_pts.nan? ? @shown_pts : @a_next_pts
    end
    if @a_next_pts.nan?
      @a_next_pts = pts_sec
    elsif pts_sec > @a_next_pts + AUDIO_EPS
      pad = ((pts_sec - @a_next_pts) * @audio_rate).to_i32
      if pad > 0
        @a_frames << AudioChunk.new(@a_next_pts,
          Bytes.new(pad * @audio_channels * 4), pad)
        @@a_padded += pad if ENV["EGUI_VIDEO_DEBUG"]?
        @a_next_pts += pad.to_f64 / @audio_rate
      end
    end
    pcm = audio_frame_to_f32(frame, n)
    if pcm
      @a_frames << AudioChunk.new(@a_next_pts, pcm, n)
      @a_next_pts += n.to_f64 / @audio_rate
    else
      @audio_note = "unsupported sample format #{frame.value.format}"
    end
  end

  # Interleave one frame of any common AVSampleFormat into f32 bytes.
  # Interleave one frame of any common AVSampleFormat into f32 bytes
  # (nil for formats outside the set). NOTE: the branches write through
  # `dst` — the case's value is the branches' Nil, so `bytes` must be the
  # explicit tail expression, not the case.
  private def audio_frame_to_f32(frame : LibFF::AVFrame*, n : Int32) : Bytes?
    fmt = frame.value.format
    ch = @audio_channels
    bytes = Bytes.new(n * ch * 4)
    dst = bytes.to_unsafe.as(Float32*)
    data = frame.value.data
    case fmt
    when LibFF::AV_SAMPLE_FMT_FLT
      data[0].to_slice(n * ch * 4).copy_to(bytes)
    when LibFF::AV_SAMPLE_FMT_S16
      src = data[0].as(Int16*)
      (n * ch).times { |i| dst[i] = src[i].to_f32 / 32768.0f32 }
    when LibFF::AV_SAMPLE_FMT_S32
      src = data[0].as(Int32*)
      (n * ch).times { |i| dst[i] = src[i].to_f32 / 2147483648.0f32 }
    when LibFF::AV_SAMPLE_FMT_U8
      src = data[0].as(UInt8*)
      (n * ch).times { |i| dst[i] = (src[i].to_f32 - 128.0f32) / 128.0f32 }
    when LibFF::AV_SAMPLE_FMT_FLTP
      (n * ch).times do |i|
        dst[i] = data[i % ch].as(Float32*)[i // ch]
      end
    when LibFF::AV_SAMPLE_FMT_S16P
      (n * ch).times do |i|
        dst[i] = data[i % ch].as(Int16*)[i // ch].to_f32 / 32768.0f32
      end
    when LibFF::AV_SAMPLE_FMT_S32P
      (n * ch).times do |i|
        dst[i] = data[i % ch].as(Int32*)[i // ch].to_f32 / 2147483648.0f32
      end
    when LibFF::AV_SAMPLE_FMT_U8P
      (n * ch).times do |i|
        dst[i] = (data[i % ch].as(UInt8*)[i // ch].to_f32 - 128.0f32) / 128.0f32
      end
    else
      return nil
    end
    bytes
  end

  # The per-UI-frame audio tick: decode ahead to the LEAD window, drop
  # stale chunks, pad a leading gap with silence, flush into the ring.
  private def pump_audio : Nil
    ring = @ring
    return unless ring
    receive_audio_frames(true)
    clock = audio_clock
    while (f = @a_frames.first?) && f.pts + f.dur(@audio_rate) <= clock - AUDIO_EPS
      @a_frames.shift
      @@a_dropped += f.frames if ENV["EGUI_VIDEO_DEBUG"]?
    end
    if (f = @a_frames.first?) && f.pts > clock + AUDIO_EPS && ring.buffered_frames.zero?
      pad = ((f.pts - clock) * @audio_rate).to_i32
      if pad > 0
        @a_frames.unshift(AudioChunk.new(clock,
          Bytes.new(pad * @audio_channels * 4), pad))
        @@a_padded += pad if ENV["EGUI_VIDEO_DEBUG"]?
      end
    end
    flush_audio_ring
  end

  # Move backlog chunks into the ring until it refuses more.
  private def flush_audio_ring : Nil
    ring = @ring
    return unless ring
    while (f = @a_frames.first?)
      accepted = ring.write(f.pcm)
      @@a_written += accepted if ENV["EGUI_VIDEO_DEBUG"]?
      if accepted >= f.frames
        @a_frames.shift
      elsif accepted > 0
        @a_frames[0] = f.advance(accepted, @audio_channels, @audio_rate)
      else
        break # ring full — retry next UI frame
      end
    end
  end

  # sws_scale the decoded frame into @rgba when it is DUE at `clock`
  # (nil = always — the open/seek paths); frames arriving early (video
  # packets read ahead to keep the audio fed) keep the displayed pixels
  # untouched. GPU-side: none — the upload is batched per UI frame (see
  # #blit), because sokol allows ONE sg_update_image per image and frame,
  # and the catch-up decode can produce several frames between two
  # repaints. Only the newest frame's pixels are displayed, so batching is
  # also cheaper.
  private def convert_frame(frame : LibFF::AVFrame*, clock : Float64? = nil) : Nil
    return if frame.value.format == @@hw_pix_fmt # hw frames have no CPU pixels
    pts = frame.value.pts
    pts = frame.value.best_effort_timestamp if pts == LibFF::NOPTS || pts < 0
    @shown_pts = pts != LibFF::NOPTS && pts >= 0 ? pts_to_seconds(pts) : @shown_pts + @frame_dur
    if clock.nil? || @shown_pts <= clock + @frame_dur * 0.6
      fw = frame.value.width
      fh = frame.value.height
      if fw != @width || fh != @height || @sws.nil? ||
         (@texture_id.zero? && !@zc)
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
        @pending_blit = false
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
      @display_pts = @shown_pts
    end
    @next_pts = @shown_pts + @frame_dur
    @frame_count += 1

    @fps_frames += 1
    if @fps_frames == 1
      @fps_wall = now_sec
    elsif (dt = now_sec - @fps_wall) >= 1.0
      @decode_fps = @fps_frames / dt
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
