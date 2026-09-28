# Hand-rolled Crystal bindings to the system FFmpeg libraries — just
# enough surface for the video player demo: demux/read/seek
# (libavformat), decode (libavcodec), RGBA conversion (libswscale),
# error strings (libavutil).
#
# The structs mirror ONLY the fields the demo reads, padded to the
# x86_64 offsets of the installed headers (libavformat 61 /
# libavcodec 61 / libavutil 59 — see the offset table in each struct).
# Everything else stays opaque; all handles are C-owned pointers.

@[Link("avformat")]
@[Link("avcodec")]
@[Link("swscale")]
@[Link("avutil")]
lib LibFF
  AVRATIONAL_SIZE = 8

  struct AVRational
    num : Int32
    den : Int32
  end

  # AVFormatContext (offsets: nb_streams=44, streams=48,
  # start_time=96, duration=104)
  struct AVFormatContext
    av_class : UInt8*    # 0
    iformat : UInt8*     # 8
    oformat : UInt8*     # 16
    priv_data : UInt8*   # 24
    pb : UInt8*          # 32
    ctx_flags : Int32    # 40
    nb_streams : UInt32  # 44
    streams : AVStream** # 48
    pad0 : UInt8[40]     # 56..95  (url, flags…)
    start_time : Int64   # 96
    duration : Int64     # 104 (AV_TIME_BASE units)
  end

  # AVStream (offsets: index=8, codecpar=16, time_base=32,
  # duration=48, avg_frame_rate=88)
  struct AVStream
    av_class : UInt8*          # 0
    index : Int32              # 8
    id : Int32                 # 12
    codecpar : AVCodecParameters* # 16
    priv_data : UInt8*         # 24
    time_base : AVRational     # 32
    start_time : Int64         # 40
    duration : Int64           # 48 (time_base units)
    nb_frames : Int64          # 56
    disposition : Int32        # 64
    discard : Int32            # 68
    sample_aspect_ratio : AVRational # 72
    metadata : UInt8*          # 80
    avg_frame_rate : AVRational # 88
  end

  # AVCodecParameters (offsets: codec_type=0, codec_id=4, width=72,
  # height=76)
  struct AVCodecParameters
    codec_type : Int32 # 0 (AVMediaType)
    codec_id : Int32   # 4 (AVCodecID)
    pad0 : UInt8[64]   # 8..71
    width : Int32      # 72
    height : Int32     # 76
  end

  # AVCodecContext (offsets: pkt_timebase=92, width=116, height=120,
  # pix_fmt=140, thread_count=656, thread_type=660)
  struct AVCodecContext
    av_class : UInt8*      # 0
    pad0 : UInt8[84]       # 8..91
    pkt_timebase : AVRational # 92
    pad1 : UInt8[16]       # 100..115
    width : Int32          # 116
    height : Int32         # 120
    pad2 : UInt8[16]       # 124..139
    pix_fmt : Int32        # 140
    pad3 : UInt8[512]      # 144..655
    thread_count : Int32   # 656
    thread_type : Int32    # 660
  end

  # AVFrame (offsets: data=0, linesize=64, width=104, height=108,
  # format=116, pts=136, best_effort_timestamp=320)
  struct AVFrame
    data : UInt8*[8]   # 0
    linesize : Int32[8] # 64
    extended_data : UInt8** # 96
    width : Int32      # 104
    height : Int32     # 108
    nb_samples : Int32 # 112
    format : Int32     # 116 (AVPixelFormat)
    pad0 : UInt8[16]   # 120..135
    pts : Int64        # 136 (pkt_timebase units)
    pad1 : UInt8[176]  # 144..319
    best_effort_timestamp : Int64 # 320
  end

  # AVPacket (offsets: pts=8, dts=16, data=24, size=32,
  # stream_index=36, flags=40, duration=64)
  struct AVPacket
    buf : UInt8*      # 0
    pts : Int64       # 8  (stream time_base units)
    dts : Int64       # 16
    data : UInt8*     # 24
    size : Int32      # 32
    stream_index : Int32 # 36
    flags : Int32     # 40
    pad0 : UInt8[20]  # 44..63
    duration : Int64  # 64
  end

  # --- libavformat ---
  fun avformat_open_input = avformat_open_input(ctx : AVFormatContext**,
                                                url : UInt8*, fmt : Void*,
                                                opts : Void**) : Int32
  fun avformat_find_stream_info = avformat_find_stream_info(
    ctx : AVFormatContext*, opts : Void**) : Int32
  fun avformat_close_input = avformat_close_input(ctx : AVFormatContext**)
  fun av_read_frame = av_read_frame(ctx : AVFormatContext*,
                                    pkt : AVPacket*) : Int32
  fun avformat_seek_file = avformat_seek_file(ctx : AVFormatContext*,
                                              stream_index : Int32,
                                              min_ts : Int64, ts : Int64,
                                              max_ts : Int64,
                                              flags : Int32) : Int32
  fun av_find_best_stream = av_find_best_stream(ic : AVFormatContext*,
                                                type : Int32,
                                                wanted_stream_nb : Int32,
                                                related_stream : Int32,
                                                decoder_ret : Void**,
                                                flags : Int32) : Int32

  # --- libavcodec ---
  fun avcodec_find_decoder = avcodec_find_decoder(id : Int32) : Void*
  fun avcodec_get_name = avcodec_get_name(id : Int32) : UInt8*
  fun avcodec_alloc_context3 = avcodec_alloc_context3(codec : Void*) : AVCodecContext*
  fun avcodec_parameters_to_context = avcodec_parameters_to_context(
    ctx : AVCodecContext*, par : AVCodecParameters*) : Int32
  fun avcodec_open2 = avcodec_open2(ctx : AVCodecContext*, codec : Void*,
                                    opts : Void**) : Int32
  fun avcodec_free_context = avcodec_free_context(ctx : AVCodecContext**)
  fun avcodec_send_packet = avcodec_send_packet(ctx : AVCodecContext*,
                                                pkt : AVPacket*) : Int32
  fun avcodec_receive_frame = avcodec_receive_frame(ctx : AVCodecContext*,
                                                    frame : AVFrame*) : Int32
  fun avcodec_flush_buffers = avcodec_flush_buffers(ctx : AVCodecContext*)
  fun av_packet_alloc = av_packet_alloc : AVPacket*
  fun av_packet_free = av_packet_free(pkt : AVPacket**)
  fun av_packet_unref = av_packet_unref(pkt : AVPacket*)

  # --- libavutil ---
  fun av_frame_alloc = av_frame_alloc : AVFrame*
  fun av_frame_free = av_frame_free(frame : AVFrame**)
  fun av_frame_unref = av_frame_unref(frame : AVFrame*)
  fun av_strerror = av_strerror(errnum : Int32, errbuf : UInt8*,
                                errbuf_size : UInt64) : Int32
  fun av_get_pix_fmt = av_get_pix_fmt(name : UInt8*) : Int32
  fun av_log_set_level = av_log_set_level(level : Int32)

  # --- libswscale ---
  fun sws_get_context = sws_getContext(src_w : Int32, src_h : Int32,
                                       src_format : Int32, dst_w : Int32,
                                       dst_h : Int32, dst_format : Int32,
                                       flags : Int32, src_filter : Void*,
                                       dst_filter : Void*,
                                       param : Void*) : Void*
  fun sws_scale = sws_scale(ctx : Void*, src_slice : UInt8**,
                            src_stride : Int32*, src_y : Int32,
                            src_h : Int32, dst : UInt8**,
                            dst_stride : Int32*) : Int32
  fun sws_free_context = sws_freeContext(ctx : Void*)

  # --- helpers -----------------------------------------------------------

  AVERROR_EOF    = -541478725 # MKTAG('E','O','F',' ') negated
  AVERROR_EAGAIN = -11        # -EAGAIN on Linux
  AVMEDIA_TYPE_VIDEO = 0
  AVSEEK_FLAG_BACKWARD = 1
  SWS_BILINEAR = 2
  AV_LOG_ERROR = 16
  AV_TIME_BASE_Q_NUM = 1
  AV_TIME_BASE_Q_DEN = 1_000_000
  # AV_NOPTS_VALUE
  NOPTS = -9223372036854775808_i64
end

# Non-C-binding helper for the demo.
module FF
  # Human-readable message for an FFmpeg error code.
  def self.error_string(code : Int32) : String
    buf = uninitialized UInt8[1024]
    if LibFF.av_strerror(code, buf.to_unsafe, 1024) == 0
      String.new(buf.to_unsafe)
    else
      "error #{code}"
    end
  end

  # Codec name for an AVCodecID ("h264", "hevc", …).
  def self.codec_name(id : Int32) : String
    ptr = LibFF.avcodec_get_name(id)
    ptr ? String.new(ptr) : "##{id}"
  end

  # Implementation name of a decoder handle ("libvpx-vp8", "h264", …) —
  # AVCodec.name is the struct's first field (const char*).
  def self.decoder_name(decoder : Void*) : String
    return "?" if decoder.null?
    name_ptr = decoder.as(Pointer(UInt8*)).value
    name_ptr ? String.new(name_ptr) : "?"
  end
end
