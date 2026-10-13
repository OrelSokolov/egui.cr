require "spec"
require "../src/egui"

# Egui::ImageCodec specs: the decode seam. `sniff` is pure Crystal
# (magic bytes, provider-independent); decode/image_size delegate to
# an installable Implementation — the headless default answers nil,
# the sokol backend wires the stb_image provider in #run. Everything
# above the seam (Context#load_image / #image_size, markdown,
# ImageView) goes through it and never touches a decoder directly.

PNG_MAGIC  = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
JPEG_MAGIC = Bytes[0xFF, 0xD8, 0xFF, 0xE0]
GIF_MAGIC  = "GIF89a".to_slice
BMP_MAGIC  = "BM".to_slice
WEBP_MAGIC = "RIFF".to_slice + Bytes.new(4, 0) + "WEBP".to_slice
ICO_MAGIC  = Bytes[0, 0, 1, 0]
TIFF_MAGIC = Bytes[0x49, 0x49, 0x2A, 0]

def pad(magic : Bytes) : Bytes
  magic + Bytes.new(16, 0)
end

# A codec stand-in recording what the seam hands it.
class RecordingCodec < Egui::ImageCodec::Implementation
  property decoded = [] of Bytes
  property probed = [] of Bytes
  property frame : Egui::ImageCodec::Frame? = nil
  property size : Egui::Vec2? = nil

  def decode(bytes : Bytes) : Egui::ImageCodec::Frame?
    @decoded << bytes
    @frame
  end

  def image_size(bytes : Bytes) : Egui::Vec2?
    @probed << bytes
    @size
  end
end

# A registry stand-in recording uploads (decode and upload are
# separate seams now: ImageCodec decodes, TextureRegistry uploads).
class UploadingRegistry < Egui::TextureRegistry
  property uploads = [] of Tuple(Int32, Int32, Bytes)

  def register_rgba(width, height, data) : UInt64
    @uploads << {width, height, data}
    (@uploads.size).to_u64
  end

  def create_stream(width, height) : UInt64
    0_u64
  end

  def update(id, width, height, data) : Nil
  end

  def destroy(id) : Nil
  end
end

describe Egui::ImageCodec do
  describe ".sniff" do
    it "recognizes formats by magic bytes" do
      Egui::ImageCodec.sniff(pad(PNG_MAGIC)).should eq(:png)
      Egui::ImageCodec.sniff(pad(JPEG_MAGIC)).should eq(:jpeg)
      Egui::ImageCodec.sniff(pad(GIF_MAGIC)).should eq(:gif)
      Egui::ImageCodec.sniff(pad(BMP_MAGIC)).should eq(:bmp)
      Egui::ImageCodec.sniff(pad(WEBP_MAGIC)).should eq(:webp)
      Egui::ImageCodec.sniff(pad(ICO_MAGIC)).should eq(:ico)
      Egui::ImageCodec.sniff(pad(TIFF_MAGIC)).should eq(:tiff)
    end

    it "returns nil for non-images and too-short buffers" do
      Egui::ImageCodec.sniff(Bytes.new(64, 0x41)).should be_nil
      Egui::ImageCodec.sniff(PNG_MAGIC).should be_nil # < 12 bytes
      Egui::ImageCodec.sniff(Bytes.empty).should be_nil
    end
  end

  it "headless default decodes and probes nothing" do
    Egui::ImageCodec.decode(pad(PNG_MAGIC)).should be_nil
    Egui::ImageCodec.image_size(pad(PNG_MAGIC)).should be_nil
  end

  it "delegates to the installed implementation (bytes verbatim)" do
    codec = RecordingCodec.new
    codec.frame = Egui::ImageCodec::Frame.new(width: 2, height: 1,
      rgba: Bytes.new(8, 0xAB))
    codec.size = Egui::Vec2.new(2.0, 1.0)
    Egui::ImageCodec.use(codec)
    begin
      frame = Egui::ImageCodec.decode(pad(PNG_MAGIC))
      frame.should_not be_nil
      frame = frame.not_nil!
      frame.width.should eq(2)
      frame.height.should eq(1)
      frame.rgba.size.should eq(2 * 1 * 4)
      sz = Egui::ImageCodec.image_size(pad(PNG_MAGIC))
      sz.should_not be_nil
      sz.not_nil!.x.should eq(2.0)
      codec.decoded.should eq([pad(PNG_MAGIC)]) # bytes pass through
      codec.probed.should eq([pad(PNG_MAGIC)])
    ensure
      Egui::ImageCodec.use(Egui::ImageCodec::Implementation.new)
    end
  end

  it "Context#load_image / #image_size go through the seam" do
    path = File.tempname("codec", ".png")
    bytes = pad(PNG_MAGIC)
    File.write(path, bytes)
    codec = RecordingCodec.new
    codec.frame = Egui::ImageCodec::Frame.new(width: 3, height: 2,
      rgba: Bytes.new(3 * 2 * 4, 0xCD))
    codec.size = Egui::Vec2.new(3.0, 2.0)
    Egui::ImageCodec.use(codec)
    registry = UploadingRegistry.new
    ctx = Egui::Context.new
    ctx.textures = registry
    begin
      ctx.load_image(path).should eq(1_u64)
      registry.uploads.should eq([{3, 2, Bytes.new(3 * 2 * 4, 0xCD)}])
      codec.decoded.should eq([bytes]) # file read → bytes to the codec

      # per-path cache: a second load decodes nothing
      ctx.load_image(path).should eq(1_u64)
      codec.decoded.clear
      ctx.load_image(path)
      codec.decoded.size.should eq(0)

      sz = ctx.image_size(path)
      sz.should_not be_nil
      sz.not_nil!.should eq(Egui::Vec2.new(3.0, 2.0))
    ensure
      Egui::ImageCodec.use(Egui::ImageCodec::Implementation.new)
      File.delete(path)
    end
  end

  it "Context#load_image answers 0 for unreadable/undecodable input" do
    ctx = Egui::Context.new
    ctx.textures = UploadingRegistry.new
    ctx.load_image("/no/such/file.png").should eq(0_u64) # unreadable
    path = File.tempname("codec_bad", ".png")
    File.write(path, Bytes.new(64, 0x41)) # a file, but not an image
    begin
      # headless default codec: decodes nothing
      ctx.load_image(path).should eq(0_u64)
      ctx.image_size(path).should be_nil
    ensure
      File.delete(path)
    end
  end
end
