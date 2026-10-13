# Image decode seam (no upstream counterpart — egui apps arrive with
# pre-decoded textures; here the core owns the pipeline).
#
# The core never knows WHO decodes PNG/JPEG/…: widgets, markdown and
# the cursor-image path see only decoded RGBA8 frames. The interface
# is bytes-in — the caller owns file/network IO:
#
#   * `ImageCodec.decode(bytes)`     — full-frame straight-alpha RGBA8
#   * `ImageCodec.image_size(bytes)` — header-only probe for
#     layout-side sizing (the provider parses the header only)
#
# `sniff` is pure Crystal (magic bytes) and provider-independent: it
# answers "which format is this" without decoding. The future
# pure-Crystal codec set and the animation-frames extension
# (`frames?(bytes)`) hang off the same seam — a provider is installed
# with `ImageCodec.use`, exactly like SystemPorts.
#
# The core stays headless: the default implementation decodes nothing
# (nil); the sokol backend wires the stb_image provider (mem-based
# shim entry points, see backend/sokol_shim.c) in `Sokol.run`.

module Egui
  module ImageCodec
    # One decoded frame: `width`×`height` straight-alpha RGBA8 pixels
    # (`rgba.size == width * height * 4`).
    record Frame, width : Int32, height : Int32, rgba : Bytes

    class_getter implementation : Implementation = Implementation.new

    # Install a decode provider (called by the backend).
    def self.use(implementation : Implementation) : Nil
      @@implementation = implementation
    end

    # Decode a full frame; nil = undecodable (unknown format, corrupt
    # data or no provider installed — the headless default).
    def self.decode(bytes : Bytes) : Frame?
      implementation.decode(bytes)
    end

    # Pixel dimensions without decoding the pixels — nil = unknown.
    def self.image_size(bytes : Bytes) : Vec2?
      implementation.image_size(bytes)
    end

    # Magic-byte sniffer: which image format these bytes are, or nil
    # for "not a recognized image" / too short. Pure Crystal — it never
    # consults the provider, so it works headless and stays correct
    # across providers. Note the DEFAULT provider (stb_image) decodes
    # :png/:jpeg/:gif/:bmp only — sniffing :webp/:ico/:tiff says what
    # the data IS, not that this provider can decode it.
    def self.sniff(bytes : Bytes) : Symbol?
      return nil if bytes.size < 12
      case
      when bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E &&
           bytes[3] == 0x47 && bytes[4] == 0x0D && bytes[5] == 0x0A &&
           bytes[6] == 0x1A && bytes[7] == 0x0A
        :png
      when bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
        :jpeg
      when bytes[0] == 'G'.ord && bytes[1] == 'I'.ord && bytes[2] == 'F'.ord
        :gif
      when bytes[0] == 'B'.ord && bytes[1] == 'M'.ord
        :bmp
      when bytes[0] == 'R'.ord && bytes[1] == 'I'.ord && bytes[2] == 'F'.ord &&
           bytes[3] == 'F'.ord && bytes[8] == 'W'.ord && bytes[9] == 'E'.ord &&
           bytes[10] == 'B'.ord && bytes[11] == 'P'.ord
        :webp
      when bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1 && bytes[3] == 0
        :ico
      when (bytes[0] == 'I'.ord && bytes[1] == 'I'.ord && bytes[2] == 0x2A &&
            bytes[3] == 0) ||
           (bytes[0] == 'M'.ord && bytes[1] == 'M'.ord && bytes[2] == 0 &&
            bytes[3] == 0x2A)
        :tiff
      else
        nil
      end
    end

    # Provider seam; the default is the headless no-op.
    class Implementation
      # Full-frame straight-alpha RGBA8 decode; nil = undecodable.
      def decode(bytes : Bytes) : Frame?
        nil
      end

      # Header-only pixel-size probe; nil = unknown.
      def image_size(bytes : Bytes) : Vec2?
        nil
      end
    end
  end
end
