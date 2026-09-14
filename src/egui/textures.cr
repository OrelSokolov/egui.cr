# Texture seam (egui `Context::load_texture` / `TextureHandle`).
#
# GPU texture handles are backend resources; the core only ever sees
# opaque UInt64 ids that flow through ImageCmd. The backend installs a
# real registry (sokol_gfx); specs run headless with the dummy below.

module Egui
  abstract class TextureRegistry
    # Upload RGBA8 pixel data; returns a texture id (0 = failure).
    abstract def register_rgba(width : Int32, height : Int32,
                               data : Bytes) : UInt64

    # Load an image file (PNG/JPEG/…) from disk; 0 = failure.
    abstract def load(path : String) : UInt64
  end

  # Headless registry: hands out deterministic incrementing ids so
  # specs can assert ImageCmd flow without a GPU. Caches loads.
  class DummyTextureRegistry < TextureRegistry
    @next_id : UInt64 = 1_u64
    @cache = {} of String => UInt64

    def register_rgba(width : Int32, height : Int32, data : Bytes) : UInt64
      id = @next_id
      @next_id += 1
      id
    end

    def load(path : String) : UInt64
      @cache[path] ||= begin
        id = @next_id
        @next_id += 1
        id
      end
    end
  end
end
