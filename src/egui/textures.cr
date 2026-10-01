# Texture seam (egui `Context::load_texture` / `TextureHandle`).
#
# GPU texture handles are backend resources; the core only ever sees
# opaque UInt64 ids that flow through ImageCmd. The backend installs a
# real registry (sokol_gfx); specs run headless with the dummy below.

module Egui
  abstract class TextureRegistry
    # True when #register_rgba hands out real GPU textures. The Svg
    # raster cache (see Svg#paint) only engages on a graphical
    # backend; the headless dummy paints nothing — specs assert on
    # the bake buffers instead (NanoSvgCr works headless).
    def graphical? : Bool
      false
    end

    # Upload RGBA8 pixel data; returns a texture id (0 = failure).
    abstract def register_rgba(width : Int32, height : Int32,
                               data : Bytes) : UInt64

    # Load an image file (PNG/JPEG/…) from disk; 0 = failure.
    abstract def load(path : String) : UInt64

    # Pixel dimensions of an image file, header-only probe (nil =
    # unknown / unreadable — the headless dummy). Layout-side sizing
    # before/without a #load.
    def image_size(path : String) : Vec2?
      nil
    end

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

    # Destroy at END of frame. Raster-cache evictions (Svg#paint)
    # happen while the frame's commands are still being built, and a
    # texture referenced by an already-emitted ImageCmd must survive
    # until the frame is drawn — the sokol backend flushes after its
    # pass; this default destroys immediately (headless draws nothing).
    def destroy_later(id : UInt64) : Nil
      destroy(id)
    end

    # True while #destroy_later entries are pending — the backend
    # must not replay its cached idle-frame commands (they may
    # reference textures awaiting destruction).
    def pending_destroys? : Bool
      false
    end

    # Run the pending #destroy_later entries (sokol: after the pass).
    def flush_destroys : Nil
    end
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
