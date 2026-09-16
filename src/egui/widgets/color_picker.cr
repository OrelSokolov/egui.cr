# Port of egui_upstream/crates/egui/src/widgets/color_picker.rs
# (simplified: SV square + hue bar + swatches; no alpha editing yet).
#
# The SV square and hue bar are small procedurally generated RGBA
# textures (created once via the TextureRegistry — GPU on the sokol
# backend, dummy ids in specs) drawn as ImageCmd and scaled up.
# Dragging either control edits the Hsva; the result flows out through
# the Ui#color_edit32 block.

module Egui
  class ColorPicker
    include Widget

    SV_SIZE  = 64
    HUE_W    = 64

    def initialize(@color : Color32)
    end

    def ui(ui : Ui) : Response
      id = ui.next_widget_id
      # Upstream `color_cache_get`: prefer the Hsva this exact color was
      # produced from — from_color of a near-white color yields hue 0
      # (red), which would flip the square and the hue cursor to red as
      # soon as a drag crosses into the white corner.
      hsv = ui.ctx.memory.color_cache[@color]? || Hsva.from_color(@color)
      size = 180.0

      # --- SV square -----------------------------------------------------
      square = Rect.from_min_size(ui.cursor, Vec2.new(size, size))
      sv_tex = sv_texture(ui.ctx, hsv.h)
      ui.painter.image(square, sv_tex)

      sv_id = id.child(1)
      sv_resp = ui.interact(square, sv_id, Sense.click_and_drag | Sense::Focusable)
      hsv = drag_sv(ui, hsv, square) if sv_resp.dragged? || sv_resp.clicked?

      # cursor dot on the square
      cx = square.left + hsv.s * square.width
      cy = square.bottom - hsv.v * square.height
      ui.painter.circle_stroke(Pos2.new(cx, cy), 5.0,
        ui.style.visuals.text_color, 2.0)

      # --- hue bar -------------------------------------------------------
      bar_h = 16.0
      bar = Rect.from_min_size(
        Pos2.new(square.left, square.bottom + 6.0),
        Vec2.new(size, bar_h))
      hue_tex = hue_texture(ui.ctx)
      # The full rainbow across the bar; the cursor marks the current
      # hue (upstream `color_slider_1d` paints the whole gradient too).
      ui.painter.image(bar, hue_tex)

      hue_id = id.child(2)
      hue_resp = ui.interact(bar, hue_id, Sense.click_and_drag | Sense::Focusable)
      hsv = drag_hue(ui, hsv, bar) if hue_resp.dragged? || hue_resp.clicked?

      # hue cursor mark
      hx = bar.left + hsv.h * bar.width
      ui.painter.line(Pos2.new(hx, bar.top - 2.0),
        Pos2.new(hx, bar.bottom + 2.0), 2.0, ui.style.visuals.text_color)

      # --- swatch + layout bookkeeping -----------------------------------
      swatch = Rect.from_min_size(Pos2.new(bar.left, bar.bottom + 6.0),
        Vec2.new(size, 12.0))
      ui.painter.rect(swatch, 3.0, hsv.to_color,
        ui.style.visuals.border_color, 1.0)

      outer = Rect.from_min_size(square.min,
        Vec2.new(size, swatch.bottom - square.top))
      ui.min_rect = ui.min_rect.union(outer)
      ui.cursor = Pos2.new(ui.max_rect.min.x,
        outer.bottom + ui.style.spacing.item_spacing.y)

      response = ui.interact(outer, id, Sense.none)
      new_color = hsv.to_color
      if new_color != @color
        response.widget_color = new_color
        response.mark_changed
      end
      # Upstream `color_cache_set`: remember which Hsva this color came
      # from so the hue survives the next frame's from_color roundtrip.
      # Bounded like upstream's FixedCache (dropped wholesale at 1024).
      cache = ui.ctx.memory.color_cache
      cache.clear if cache.size >= 1024
      cache[new_color] = hsv
      response
    end

    private def drag_sv(ui : Ui, hsv : Hsva, rect : Rect) : Hsva
      pos = ui.ctx.input.pointer_pos.not_nil!
      s = ((pos.x - rect.left) / rect.width).clamp(0.0, 1.0)
      v = (1.0 - (pos.y - rect.top) / rect.height).clamp(0.0, 1.0)
      Hsva.new(hsv.h, s, v, hsv.a)
    end

    private def drag_hue(ui : Ui, hsv : Hsva, rect : Rect) : Hsva
      pos = ui.ctx.input.pointer_pos.not_nil!
      h = ((pos.x - rect.left) / rect.width).clamp(0.0, 0.9999)
      Hsva.new(h, hsv.s, hsv.v, hsv.a)
    end

    # One 64x64 texture: horizontal saturation, vertical value, baked
    # at a hue quantized to 1/60 steps — cached in Memory#texture_cache
    # so at most 60 small textures ever exist per picker.
    private def sv_texture(ctx : Context, hue : Float64) : UInt64
      step = (hue * 60.0).floor.to_i.clamp(0, 59)
      key = "color_picker/sv/#{step}"
      if (cached = ctx.memory.texture_cache[key]?) && !cached.zero?
        return cached
      end

      data = Bytes.new(SV_SIZE * SV_SIZE * 4)
      h = step.to_f64 / 60.0
      SV_SIZE.times do |y|
        SV_SIZE.times do |x|
          s = x.to_f64 / (SV_SIZE - 1)
          v = 1.0 - y.to_f64 / (SV_SIZE - 1)
          c = Hsva.new(h, s, v, 1.0).to_color
          i = (y * SV_SIZE + x) * 4
          data[i] = c.r
          data[i + 1] = c.g
          data[i + 2] = c.b
          data[i + 3] = 255_u8
        end
      end
      id = ctx.textures.register_rgba(SV_SIZE, SV_SIZE, data)
      ctx.memory.texture_cache[key] = id unless id.zero?
      id
    end

    # One 64x1 texture: hue gradient across the full strip (cached).
    private def hue_texture(ctx : Context) : UInt64
      key = "color_picker/hue"
      if (cached = ctx.memory.texture_cache[key]?) && !cached.zero?
        return cached
      end

      data = Bytes.new(HUE_W * 4)
      HUE_W.times do |x|
        c = Hsva.new(x.to_f64 / HUE_W, 1.0, 1.0, 1.0).to_color
        i = x * 4
        data[i] = c.r
        data[i + 1] = c.g
        data[i + 2] = c.b
        data[i + 3] = 255_u8
      end
      id = ctx.textures.register_rgba(HUE_W, 1, data)
      ctx.memory.texture_cache[key] = id unless id.zero?
      id
    end
  end
end
