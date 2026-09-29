# Minimal PNG codec for the Paint demo — pure Crystal, stdlib only
# (Compress::Zlib + CRC32), cross-platform by construction.
#
# Encode: 8-bit RGBA, one IDAT zlib stream.
# Decode: 8-bit gray / RGB / palette / gray+A / RGBA, bit depth 8 and
# 16 (high byte kept), non-interlaced. 1/2/4-bit indexed and Adam7 are
# rejected with a clear message — beyond a Paint demo's needs.

require "compress/zlib"

module PaintPng
  @@crc_table : Array(UInt32)? = nil
  SIGNATURE = Bytes[137, 80, 78, 71, 13, 10, 26, 10]

  class PngError < Exception
  end

  def self.encode(rgba : Bytes, width : Int32, height : Int32) : Bytes
    raise PngError.new("empty image") if width <= 0 || height <= 0
    stride = width * 4
    raw = Bytes.new((stride + 1) * height)
    height.times do |y|
      dst = y * (stride + 1)
      raw[dst] = 0_u8 # filter: none
      (rgba + y * stride).copy_to(raw.to_unsafe + dst + 1, stride)
    end

    out_io = IO::Memory.new
    out_io.write(SIGNATURE)

    ihdr = Bytes.new(13)
    write_u32(ihdr, 0, width)
    write_u32(ihdr, 4, height)
    ihdr[8] = 8_u8  # bit depth
    ihdr[9] = 6_u8  # color type: RGBA
    ihdr[10] = 0_u8 # compression
    ihdr[11] = 0_u8 # filter
    ihdr[12] = 0_u8 # interlace
    chunk(out_io, "IHDR", ihdr)

    comp = IO::Memory.new
    writer = Compress::Zlib::Writer.new(comp)
    writer.write(raw)
    writer.close
    chunk(out_io, "IDAT", comp.to_slice)
    chunk(out_io, "IEND", Bytes.empty)
    out_io.to_slice
  end

  record(Image, width : Int32, height : Int32, rgba : Bytes)

  def self.decode(data : Bytes) : Image
    raise PngError.new("not a PNG (bad signature)") unless data[0, 8] == SIGNATURE
    pos = 8
    width = height = 0
    bit_depth = 0
    color_type = 0
    interlace = 0
    palette = Bytes.empty
    trns = Bytes.empty
    idat = IO::Memory.new

    while pos + 8 <= data.size
      length = read_u32(data, pos)
      kind = String.new(data[pos + 4, 4])
      body = data[pos + 8, length]
      case kind
      when "IHDR"
        width = read_u32(body, 0)
        height = read_u32(body, 4)
        bit_depth = body[8]
        color_type = body[9]
        interlace = body[12]
      when "PLTE" then palette = body.dup
      when "tRNS" then trns = body.dup
      when "IDAT" then idat.write(body)
      when "IEND" then break
      end
      pos += 12 + length
    end
    raise PngError.new("missing IHDR") if width == 0
    raise PngError.new("interlaced PNG not supported") if interlace != 0

    channels = {0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[color_type]? ||
               raise(PngError.new("unsupported color type #{color_type}"))
    sub_byte = color_type == 3 && bit_depth < 8 # indexed 1/2/4-bit
    unless bit_depth == 8 || (bit_depth == 16 && color_type != 3) || sub_byte
      raise PngError.new("unsupported bit depth #{bit_depth} " \
                         "(color type #{color_type})")
    end
    bits_per_px = channels * bit_depth
    bytes_per_px = {(bits_per_px + 7) // 8, 1}.max

    reader = Compress::Zlib::Reader.new(idat.rewind)
    filtered = reader.getb_to_end
    reader.close

    stride = (width * bits_per_px + 7) // 8
    raise PngError.new("truncated image data") if filtered.size < stride * height

    # Un-filter (PNG 9.2: byte-wise paeth predictor). The filter unit
    # is bytes, even for sub-byte pixels.
    lines = Array(Bytes).new(height) { |i| filtered[(stride + 1) * i + 1, stride] }
    bpp = bytes_per_px
    height.times do |y|
      ft = filtered[(stride + 1) * y]
      line = lines[y]
      prev = y > 0 ? lines[y - 1] : nil
      stride.times do |i|
        a = (i >= bpp ? line[i - bpp] : 0_u8).to_i32
        b = (prev ? prev.not_nil![i] : 0_u8).to_i32
        c = (prev && i >= bpp) ? prev.not_nil![i - bpp].to_i32 : 0
        v = line[i].to_i32
        line[i] = case ft
                  when 1 then ((v + a) & 0xFF).to_u8
                  when 2 then ((v + b) & 0xFF).to_u8
                  when 3 then ((v + (a + b) // 2) & 0xFF).to_u8
                  when 4
                    p = a + b - c
                    pa, pb, pc = (p - a).abs, (p - b).abs, (p - c).abs
                    best = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                    ((v + best) & 0xFF).to_u8
                  else v.to_u8
                  end
      end
    end

    rgba = Bytes.new(width.to_i64 * height * 4)
    height.times do |y|
      line = lines[y]
      width.times do |x|
        src = sub_byte ? line : line + x * bytes_per_px
        r = g = b = 0_u8
        a = 255_u8
        case color_type
        when 0 # gray
          v = bit_depth == 16 ? src[0] : src[0]
          r = g = b = v
        when 2 # rgb
          r, g, b = src[0], src[1], src[2]
        when 3 # palette
          idx = sub_byte ? sub_byte_index(line, x, bit_depth.to_i32) : src[0].to_i32
          if idx * 3 + 2 < palette.size
            r = palette[idx * 3]
            g = palette[idx * 3 + 1]
            b = palette[idx * 3 + 2]
          end
          a = trns[idx]? || 255_u8
        when 4 # gray + alpha
          v = src[0]
          r = g = b = v
          a = src[1]
        when 6 # rgba
          r, g, b, a = src[0], src[1], src[2], src[3]
        end
        dst = (y.to_i64 * width + x) * 4
        rgba[dst] = r
        rgba[dst + 1] = g
        rgba[dst + 2] = b
        rgba[dst + 3] = a
      end
    end
    Image.new(width, height, rgba)
  end

  # Pixel index out of a packed sub-byte (1/2/4-bit) indexed scanline,
  # MSB-first within each byte.
  private def self.sub_byte_index(line : Bytes, x : Int32, depth : Int32) : Int32
    bit = x * depth
    byte = line[bit // 8].to_i32
    shift = 8 - depth - (bit % 8)
    (byte >> shift) & ((1 << depth) - 1)
  end

  def self.decode_file(path : String) : Image
    decode(File.read(path).to_slice)
  rescue e : IO::Error | KeyError | IndexError | ArgumentError
    raise PngError.new("#{path}: #{e.message}")
  end

  # Standard CRC-32 (PNG/others): reflected 0xEDB88320 table. This
  # Crystal build's stdlib ships no crc32 module, so it lives here.
  private def self.crc_table : Array(UInt32)
    @@crc_table ||= begin
      table = Array(UInt32).new(256, 0_u32)
      256.times do |n|
        c = n.to_u32
        8.times do
          c = (c >> 1) ^ (c & 1 != 0 ? 0xEDB88320_u32 : 0_u32)
        end
        table[n] = c
      end
      table
    end
  end

  private def self.crc32(data : Bytes) : UInt32
    c = 0xFFFFFFFF_u32
    table = crc_table
    data.each { |b| c = table[((c ^ b) & 0xFF).to_i32] ^ (c >> 8) }
    c ^ 0xFFFFFFFF_u32
  end

  private def self.chunk(io : IO, kind : String, body : Bytes) : Nil
    io.write_bytes(body.size.to_u32, IO::ByteFormat::BigEndian)
    io.write(kind.to_slice)
    io.write(body)
    buf = IO::Memory.new(kind.bytesize + body.size)
    buf.write(kind.to_slice)
    buf.write(body)
    io.write_bytes(crc32(buf.to_slice), IO::ByteFormat::BigEndian)
  end

  private def self.write_u32(buf : Bytes, at : Int32, v : Int32) : Nil
    buf[at] = (v >> 24).to_u8
    buf[at + 1] = (v >> 16).to_u8
    buf[at + 2] = (v >> 8).to_u8
    buf[at + 3] = v.to_u8
  end

  private def self.read_u32(buf : Bytes, at : Int32) : Int32
    (buf[at].to_i32 << 24) | (buf[at + 1].to_i32 << 16) |
      (buf[at + 2].to_i32 << 8) | buf[at + 3].to_i32
  end
end
