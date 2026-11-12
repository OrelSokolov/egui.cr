require "minaudio"

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
  @fps_accum : Float64 = 0.0
  @fps_frames : Int32 = 0
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
    LibFF.av_log_set_level(LibFF::AV_LOG_ERROR)
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
    if LibFF.avcodec_parameters_to_context(cctx, st.value.codecpar) < 0 ||
       LibFF.avcodec_open2(cctx, codec, nil) < 0
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

    @rgba = Bytes.new(@width * @height * 4)
    @texture_id = @ctx.textures.create_stream(@width, @height)
    if @texture_id.zero?
      @error = "texture creation failed"
      close
      return false
    end

    open_audio(path)

    @path = path
    @error = nil
    @frame_count = 0
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
    @shown_pts = @display_pts = @next_pts = 0.0
    @frame_count = 0
    @video_eof = false
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
  def advance : Nil
    return unless playing?
    if @ring
      feed_audio(audio_clock)
      pump_audio
      budget = 8
      while budget > 0 && !@video_eof &&
            @next_pts <= audio_clock + @frame_dur * 0.6
        break unless decode_next_frame(audio_clock)
        budget -= 1
      end
      mark_eof if @video_eof && audio_drained?
    else
      now = now_sec
      budget = 8
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
      STDERR.printf("video: %-7s pts=%6.2f frames=%-5d fps=%.1f px0=%d,%d,%d,%d avg=%d,%d,%d adv=%d dec=%d blit=%.0fms upd=%.0fms/%d a[%s]\n",
        @state.to_s.downcase, @display_pts, @frame_count, @decode_fps,
        r || -1, g || -1, b || -1, a || -1, ar, ag, ab,
        @@advance_calls, @@decode_calls, @@blit_ms, upd_ms, upd_n, astat)
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
        convert_frame(frame, clock)
        return true
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
            convert_frame(frame, clock)
            return true
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
    pts = frame.value.pts
    pts = frame.value.best_effort_timestamp if pts == LibFF::NOPTS || pts < 0
    @shown_pts = pts != LibFF::NOPTS && pts >= 0 ? pts_to_seconds(pts) : @shown_pts + @frame_dur
    if clock.nil? || @shown_pts <= clock + @frame_dur * 0.6
      fw = frame.value.width
      fh = frame.value.height
      if fw != @width || fh != @height || @sws.nil?
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
