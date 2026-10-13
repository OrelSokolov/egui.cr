# An interactive image VIEWER — pan/zoom canvas for artwork a user
# inspects, not a widget for static UI imagery (no upstream counterpart;
# egui keeps viewers app-side). Sources:
#
#   * an `Egui::Svg` — rasterized through the shared Svg bucket cache
#     with a startup PREWARM (all reachable power-of-two buckets bake
#     one per frame before a hand can reach the window), so a pinch
#     crossing a bucket boundary is always a cache hit and the frame
#     cost is one GPU-resampled quad — the video-player model. See
#     examples/multitouch_demo.cr.
#   * an image file (PNG/JPEG/… via Context#load_image) — one texture,
#     GPU-resampled; nothing to prewarm.
#
# Gestures: one finger / left drag pans, two-finger pinch (mobile) or
# wheel (desktop) zooms at the focal point, double-click/double-tap
# resets. The widget fills the available space.
#
#   view = Egui::ImageView.new("art", app_svg, Egui::Vec2.new(300, 300))
#   ctx.central_panel do |ui|
#     view.ui(ui)
#   end
#
# WHEN TO USE: dedicated viewing surfaces — artwork, photos, maps,
# zoomable documents. NOT for icons/labels/decorations: those go
# through `ui.svg` (one exact-size bake, one texture, forever) — the
# bucket prewarm here spends ~4 raster bakes (~21 MB at the 2048 cap)
# up front, which static UI imagery would waste.

module Egui
  class ImageView
    include Widget

    # Smallest/largest zoom the gestures can reach (the prewarm set is
    # derived from this range — see #enqueue_prewarm).
    property min_scale : Float64 = 0.1
    property max_scale : Float64 = 12.0
    # Largest raster bucket (px) for SVG sources — the memory cap of
    # the prewarm set. 2048 keeps the full set ≈ 21 MB.
    property max_bucket : Int32 = 2048
    # Backing painted behind the image (nil = none). Defaults to the
    # panel fill so the viewport reads as a canvas.
    property background : Color32?
    property rounding : Float64 = 8.0

    getter scale : Float64
    getter offset : Vec2
    # Drawn size at scale 1.0 — the SVG's given base or the raster
    # probe (Context#image_size) adopted on first load.
    getter base : Vec2

    @pid : Id
    @svg : Svg?
    @image_path : String?
    @base : Vec2
    @base_given : Bool
    @offset = Vec2.zero
    @scale = 1.0
    # Raster-source texture id (resolved lazily — loading needs a
    # Context). 0 = not loaded / headless.
    @texture_id : UInt64 = 0_u64
    # Prewarm queue (SVG only): buckets left to bake, one per frame.
    @prewarm = [] of Int32
    # pixels_per_point values already enqueued — a monitor move to a
    # different density enqueues the new reachable set the same way.
    @prewarm_ppps = Set(Float64).new

    # SVG source: `svg` is the app's retained Svg (parsed once),
    # `base` its drawn size in points at scale 1.0.
    def initialize(id : String, svg : Svg, base : Vec2)
      @pid = Id.from("image_view/#{id}")
      @svg = svg
      @image_path = nil
      @base_given = true
      @base = base
    end

    # Raster source (PNG/JPEG/…): `base` overrides the pixel size
    # probe (Context#image_size — the ImageCodec seam) when given.
    def initialize(id : String, image_path : String, base : Vec2? = nil)
      @pid = Id.from("image_view/#{id}")
      @svg = nil
      @image_path = image_path
      @base_given = !base.nil?
      @base = base || Vec2.new(100.0, 100.0)
    end

    def inspector_label : String?
      @svg ? "image view (svg)" : "image view #{File.basename(@image_path.to_s)}"
    end

    # Back to scale 1.0, centered (also what a double-click does).
    def reset : Nil
      @scale = 1.0
      @offset = Vec2.zero
    end

    def ui(ui : Ui) : Response
      ctx = ui.ctx
      rect = ui.allocate_at_least(ui.available_size)
      response = ui.interact(rect, @pid, Sense.click_and_drag)
      input = ctx.input

      # --- gestures (pan, zoom, reset) --------------------------------
      @offset = @offset + response.drag_delta if response.dragged?
      {% if flag?(:android) %}
        # Two-finger pan: the sokol shim re-emits the centroid delta as
        # scroll (positive = content moves down/left).
        @offset = @offset + input.scroll
      {% end %}

      # Zoom: pinch on touch, wheel on desktop. The two-finger centroid
      # (zoom_pos) is the focal point; the wheel zooms at the pointer.
      factor = input.zoom_delta
      {% unless flag?(:android) || flag?(:ios) %}
        factor *= 1.1 ** (-input.scroll.y) unless input.scroll.y.zero?
      {% end %}
      focal = {% if flag?(:android) || flag?(:ios) %}
        input.zoom_pos
      {% else %}
        input.zoom_pos || input.pointer_pos
      {% end %}
      if factor != 1.0 && (f = focal)
        new_scale = (@scale * factor).clamp(min_scale, max_scale)
        applied = new_scale / @scale
        rel = (f - rect.center) - @offset # focal in image units
        @offset = (f - rect.center) - rel * applied
        @scale = new_scale
      end
      reset if response.double_clicked?

      # Repaint only while the view actually moves — an idle viewer
      # costs no frames (the viewport3d contract).
      ctx.request_repaint if response.dragged? || factor != 1.0

      # --- paint --------------------------------------------------------
      painter = ui.painter
      painter.rect(rect.shrink(1.0), rounding,
        @background || ui.ctx.style.visuals.window_fill,
        ui.ctx.style.visuals.window_stroke, 1.0)
      saved_clip = painter.clip
      painter.clip = rect
      size = Vec2.new(@base.x * @scale, @base.y * @scale)
      center = rect.center + @offset
      img_rect = Rect.from_min_size(
        Pos2.new(center.x - size.x / 2.0, center.y - size.y / 2.0), size)
      if (svg = @svg) && ctx.textures.graphical? &&
         (id = svg.raster_texture_id(ctx.textures,
           current_bucket(ctx), current_bucket(ctx))) > 0_u64
        painter.image(img_rect, id)
      elsif (path = @image_path) && ctx.textures.graphical?
        ensure_texture(ctx, path)
        painter.image(img_rect, @texture_id) unless @texture_id.zero?
      end
      painter.clip = saved_clip

      # --- SVG prewarm drain --------------------------------------------
      # Bake ONE pending bucket per frame after the draw, and keep the
      # runtime awake until the queue empties (update runs only while
      # there is work). Nothing animates in the first frames, so a
      # long bake there is invisible; by the first gesture every
      # bucket is a cache hit.
      if (svg = @svg) && ctx.textures.graphical?
        enqueue_prewarm(ctx)
        if (bucket = @prewarm.shift?)
          svg.raster_texture_id(ctx.textures, bucket, bucket)
          ctx.request_repaint unless @prewarm.empty?
        end
      end

      response.on_hover_and_drag_cursor(CursorIcon::Grabbing)
      response.widget_text = "image_view"
      response
    end

    # The raster bucket for the CURRENT scale: nearest power of two at
    # or above the drawn pixel size (largest dimension), clamped to
    # 256..max_bucket. The GPU resamples the quad in between buckets.
    private def current_bucket(ctx : Context) : Int32
      px = {@base.x, @base.y}.max * @scale * ctx.pixels_per_point
      clamp_bucket(2.0 ** Math.log2(px).ceil)
    end

    private def clamp_bucket(b : Float64) : Int32
      { {b, 256.0}.max, @max_bucket.to_f64 }.min.round.to_i
    end

    # Queue every bucket reachable from min_scale..max_scale at this
    # frame's pixels_per_point (once per distinct ppp — a monitor move
    # to another density enqueues its set the same way). Descending so
    # the expensive buckets land in the earliest, least visible frames.
    private def enqueue_prewarm(ctx : Context) : Nil
      ppp = ctx.pixels_per_point
      return if @prewarm_ppps.includes?(ppp)
      @prewarm_ppps << ppp
      span = {@base.x, @base.y}.max
      lo = clamp_bucket(2.0 ** Math.log2(span * min_scale * ppp).ceil)
      hi = clamp_bucket(2.0 ** Math.log2(span * max_scale * ppp).ceil)
      b = hi
      while b >= lo
        @prewarm << b unless @prewarm.includes?(b)
        b //= 2
      end
    end

    # Raster source: load once (Context#load_image caches per path)
    # and adopt the file's pixel size when the app gave no base.
    private def ensure_texture(ctx : Context, path : String) : Nil
      if @texture_id.zero?
        @texture_id = ctx.load_image(path)
        if !@base_given && (sz = ctx.image_size(path))
          @base = sz
        end
      end
    end
  end
end
