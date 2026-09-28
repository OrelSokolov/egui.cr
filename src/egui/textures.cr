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

    # Create an EMPTY updatable RGBA8 texture for pixels that change
    # every frame (decoded video, camera frames); 0 = failure. Content
    # is undefined until the first #update.
    abstract def create_stream(width : Int32, height : Int32) : UInt64

    # Push fresh RGBA8 pixels into a texture created by #create_stream
    # (same size it was created with).
    abstract def update(id : UInt64, width : Int32, height : Int32,
                        data : Bytes) : Nil

    # Release a texture from #register_rgba, #load or #create_stream.
    abstract def destroy(id : UInt64) : Nil
  end

  # Headless registry: hands out deterministic incrementing ids so
  # specs can assert ImageCmd flow without a GPU. Caches loads.
  class DummyTextureRegistry < TextureRegistry
    @next_id : UInt64 = 1_u64
    @cache = {} of String => UInt64
    @alive = Set(UInt64).new

    def register_rgba(width : Int32, height : Int32, data : Bytes) : UInt64
      id = @next_id
      @next_id += 1
      @alive << id
      id
    end

    def load(path : String) : UInt64
      @cache[path] ||= begin
        id = @next_id
        @next_id += 1
        @alive << id
        id
      end
    end

    def create_stream(width : Int32, height : Int32) : UInt64
      register_rgba(width, height, Bytes.empty)
    end

    def update(id : UInt64, width : Int32, height : Int32,
               data : Bytes) : Nil
      # headless: nothing to push
    end

    def destroy(id : UInt64) : Nil
      @alive.delete(id)
    end
  end
end
