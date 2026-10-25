# A Lottie widget: the animated twin of Svg — the Player's clock picks
# the source frame, this widget rasterizes it into ONE updatable stream
# texture (the video/camera pipeline) and replays it as a pixel-grid-
# snapped quad. Re-renders happen ONLY when the quantized frame number
# changes (a 30 fps asset in a 60 fps UI rasterizes every other frame),
# and the GPU upload is batched to one #update per UI frame — sokol's
# once-per-frame rule (VideoPlayer's pending_blit pattern).
#
# The stream texture lives in a class-level cache keyed by the Player
# (app-owned, like VideoPlayer), because `ui.lottie` builds a fresh
# widget per frame while the GPU state must persist. Release it
# explicitly with .release when discarding a player.
#
# Headless (non-graphical TextureRegistry) builds allocate the widget
# rect but paint nothing — specs assert on the render/update flow with
# a recording registry instead (see spec/lottie_spec.cr).

module Egui
  class LottieWidget
    include Widget

    # Square by default; falls back to the renderer's own viewport
    # (512 for a broken renderer — a bare <svg> without a viewBox
    # behaves the same way in Svg).
    property size : Vec2

    @player : Lottie::Player

    def initialize(@player : Lottie::Player,
                   size : Vec2? = nil)
      r = @player.renderer
      @size = size || Vec2.new(
        (r.width > 0 ? r.width : 512).to_f64,
        (r.height > 0 ? r.height : 512).to_f64)
    end

    def ui(ui : Ui) : Response
      rect = ui.allocate_at_least(@size)
      paint(ui, rect)
      ui.interact(rect, ui.next_widget_id, Sense.none)
    end

    # Per-player GPU state: the stream texture, its backing buffer and
    # the frame currently baked into it.
    class Stream
      property tex_id : UInt64
      property w : Int32
      property h : Int32
      property buf : Bytes
      # Frame whose pixels are in @buf (-1 = none yet).
      property last_frame : Int32 = -1
      # Newest frame is in @buf but not on the GPU yet (batched: one
      # texture upload per UI frame).
      property? pending : Bool = false

      def initialize(@tex_id : UInt64, @w : Int32, @h : Int32)
        @buf = Bytes.new(w * h * 4)
      end
    end

    @@streams = {} of Lottie::Player => Stream

    # Destroy a player's stream texture (apps discarding a Player call
    # this — GC finalization cannot reach the registry).
    def self.release(player : Lottie::Player,
                     registry : TextureRegistry) : Nil
      if (stream = @@streams.delete(player))
        registry.destroy_later(stream.tex_id) unless stream.tex_id.zero?
      end
    end

    def paint(ui : Ui, rect : Rect) : Nil
      player = @player
      player.advance
      return unless ui.ctx.textures.graphical?
      registry = ui.ctx.textures
      r = player.renderer
      # Aspect-preserving fit, then bake/draw at whole physical pixels
      # (the Svg#paint 1:1 texel contract — the quad samples without
      # resampling blur).
      iw = r.width > 0 ? r.width.to_f64 : 512.0
      ih = r.height > 0 ? r.height.to_f64 : 512.0
      scale = {rect.width / iw, rect.height / ih}.min
      ppp = ui.ctx.pixels_per_point
      tw = {(iw * scale * ppp).round.to_i, 1}.max
      th = {(ih * scale * ppp).round.to_i, 1}.max
      return if tw <= 0 || th <= 0
      stream = stream_for(registry, player, tw, th)
      return if stream.nil?

      frame = player.current_frame
      if frame != stream.last_frame
        Egui::Bench.count("lottie.render")
        if r.render(frame, stream.buf, tw, th)
          stream.last_frame = frame
          stream.pending = true
        end
      end
      if stream.pending?
        registry.update(stream.tex_id, tw, th, stream.buf)
        stream.pending = false
      end

      qw = tw / ppp
      qh = th / ppp
      cx = rect.left + rect.width / 2.0
      cy = rect.top + rect.height / 2.0
      x0 = (((cx - qw / 2.0) * ppp).round) / ppp
      y0 = (((cy - qh / 2.0) * ppp).round) / ppp
      ui.painter.image(Rect.from_min_size(Pos2.new(x0, y0),
        Vec2.new(qw, qh)), stream.tex_id)
    end

    # Fetch/create the player's stream texture, recreating it when the
    # target pixel size changed (window resize / ppp change). The old
    # texture dies via destroy_later — this frame may already have
    # emitted an ImageCmd for it.
    private def stream_for(registry : TextureRegistry, player : Lottie::Player,
                           w_px : Int32, h_px : Int32) : Stream?
      stream = @@streams[player]?
      if stream.nil? || stream.w != w_px || stream.h != h_px
        id = registry.create_stream(w_px, h_px)
        return nil if id.zero?
        registry.destroy_later(stream.tex_id) if stream && !stream.tex_id.zero?
        stream = Stream.new(id, w_px, h_px)
        @@streams[player] = stream
      end
      stream
    end
  end
end
