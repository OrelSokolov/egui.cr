# Port of egui_upstream/crates/egui/src/widgets/color_picker.rs
# (simplified: SV square + hue bar + alpha bar + swatch; no hue wheel).
#
# The SV square and hue bar are small procedurally generated RGBA
# textures (created once via the TextureRegistry — GPU on the sokol
# backend, dummy ids in specs) drawn as ImageCmd and scaled up.
# The alpha bar is a cached white→transparent ramp texture tinted with
# the current RGB over a checkerboard. Dragging any control edits the
# Hsva; the result flows out through the Ui#color_edit32 block.

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

      # --- alpha bar -----------------------------------------------------
      alpha = Rect.from_min_size(
        Pos2.new(square.left, bar.bottom + 6.0),
        Vec2.new(size, bar_h))
      paint_checkerboard(ui.painter, alpha)
      # The cached ramp is white with alpha 0→1; tinting with the opaque
      # version of the current color turns it into that color's alpha
      # gradient (ImageCmd tint multiplies per texel).
      tint = Hsva.new(hsv.h, hsv.s, hsv.v, 1.0).to_color
      ui.painter.image(alpha, alpha_texture(ui.ctx), tint: tint)

      alpha_id = id.child(3)
      alpha_resp = ui.interact(alpha, alpha_id,
        Sense.click_and_drag | Sense::Focusable)
      hsv = drag_alpha(ui, hsv, alpha) if alpha_resp.dragged? || alpha_resp.clicked?

      # alpha cursor mark
      ax = alpha.left + hsv.a * alpha.width
      ui.painter.line(Pos2.new(ax, alpha.top - 2.0),
        Pos2.new(ax, alpha.bottom + 2.0), 2.0, ui.style.visuals.text_color)

      # --- swatch ---------------------------------------------------------
      swatch = Rect.from_min_size(Pos2.new(bar.left, alpha.bottom + 6.0),
        Vec2.new(size, 12.0))
      paint_checkerboard(ui.painter, swatch)
      ui.painter.rect(swatch, 3.0, hsv.to_color,
        ui.style.visuals.button_stroke, 1.0)

      # --- name / hex / rgba readout --------------------------------------
      # Real selectable Labels (caret, drag-select, Ctrl+C, context
      # menu) — the values are copyable text, not painted glyphs.
      color = hsv.to_color
      hex_font = (ui.style.font_size * 0.8).round
      ui.cursor = Pos2.new(square.left, swatch.bottom + 4.0)
      readout = [
        ui.add(Label.new(
          RichText.new(self.class.color_name(color)).bold, wrap: false)),
        ui.add(Label.new(
          RichText.new(hex_text(color)).size(hex_font), wrap: false)),
        ui.add(Label.new(
          RichText.new(rgba_text(color)).size(hex_font), wrap: false)),
      ]

      outer = Rect.from_min_size(square.min,
        Vec2.new({size, readout.max_of(&.rect.right) - square.left}.max,
          readout.last.rect.bottom - square.top))
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

    private def drag_alpha(ui : Ui, hsv : Hsva, rect : Rect) : Hsva
      pos = ui.ctx.input.pointer_pos.not_nil!
      a = ((pos.x - rect.left) / rect.width).clamp(0.0, 1.0)
      Hsva.new(hsv.h, hsv.s, hsv.v, a)
    end

    # `#RRGGBB` — the common 6-digit form; alpha lives in the rgba row.
    private def hex_text(color : Color32) : String
      "#%02X%02X%02X" % [color.r, color.g, color.b]
    end

    # 8-bit channels, matching the picker's own byte-level alpha bar.
    private def rgba_text(color : Color32) : String
      "rgba(%d, %d, %d, %d)" % [color.r, color.g, color.b, color.a]
    end

    # Common CSS colors the readout names the swatch with: nearest match
    # in RGB space, so off-table colors show their closest name.
    COLOR_NAMES = {
      {"Black", Color32.rgb(0, 0, 0)},           {"White", Color32.rgb(255, 255, 255)},
      {"Gray", Color32.rgb(128, 128, 128)},      {"Silver", Color32.rgb(192, 192, 192)},
      {"Dark Gray", Color32.rgb(169, 169, 169)}, {"Light Gray", Color32.rgb(211, 211, 211)},
      {"Slate Gray", Color32.rgb(112, 128, 144)},
      {"Red", Color32.rgb(255, 0, 0)},           {"Dark Red", Color32.rgb(139, 0, 0)},
      {"Crimson", Color32.rgb(220, 20, 60)},     {"Firebrick", Color32.rgb(178, 34, 34)},
      {"Salmon", Color32.rgb(250, 128, 114)},    {"Pink", Color32.rgb(255, 192, 203)},
      {"Hot Pink", Color32.rgb(255, 105, 180)},  {"Magenta", Color32.rgb(255, 0, 255)},
      {"Orange", Color32.rgb(255, 165, 0)},      {"Dark Orange", Color32.rgb(255, 140, 0)},
      {"Coral", Color32.rgb(255, 127, 80)},      {"Tomato", Color32.rgb(255, 99, 71)},
      {"Gold", Color32.rgb(255, 215, 0)},        {"Yellow", Color32.rgb(255, 255, 0)},
      {"Khaki", Color32.rgb(240, 230, 140)},     {"Brown", Color32.rgb(165, 42, 42)},
      {"Saddle Brown", Color32.rgb(139, 69, 19)}, {"Chocolate", Color32.rgb(210, 105, 30)},
      {"Sandy Brown", Color32.rgb(244, 164, 96)}, {"Tan", Color32.rgb(210, 180, 140)},
      {"Beige", Color32.rgb(245, 245, 220)},     {"Maroon", Color32.rgb(128, 0, 0)},
      {"Olive", Color32.rgb(128, 128, 0)},       {"Dark Olive Green", Color32.rgb(85, 107, 47)},
      {"Yellow Green", Color32.rgb(154, 205, 50)}, {"Green Yellow", Color32.rgb(173, 255, 47)},
      {"Green", Color32.rgb(0, 128, 0)},         {"Dark Green", Color32.rgb(0, 100, 0)},
      {"Forest Green", Color32.rgb(34, 139, 34)}, {"Sea Green", Color32.rgb(46, 139, 87)},
      {"Spring Green", Color32.rgb(0, 255, 127)}, {"Lime", Color32.rgb(0, 255, 0)},
      {"Pale Green", Color32.rgb(152, 251, 152)}, {"Mint Cream", Color32.rgb(245, 255, 250)},
      {"Teal", Color32.rgb(0, 128, 128)},        {"Turquoise", Color32.rgb(64, 224, 208)},
      {"Aqua", Color32.rgb(0, 255, 255)},        {"Steel Blue", Color32.rgb(70, 130, 180)},
      {"Midnight Blue", Color32.rgb(25, 25, 112)}, {"Navy", Color32.rgb(0, 0, 128)},
      {"Blue", Color32.rgb(0, 0, 255)},          {"Royal Blue", Color32.rgb(65, 105, 225)},
      {"Cornflower Blue", Color32.rgb(100, 149, 237)}, {"Sky Blue", Color32.rgb(135, 206, 235)},
      {"Light Sky Blue", Color32.rgb(135, 206, 250)}, {"Dodger Blue", Color32.rgb(30, 144, 255)},
      {"Deep Sky Blue", Color32.rgb(0, 191, 255)},
      {"Indigo", Color32.rgb(75, 0, 130)},       {"Purple", Color32.rgb(128, 0, 128)},
      {"Violet", Color32.rgb(238, 130, 238)},    {"Dark Violet", Color32.rgb(148, 0, 211)},
      {"Blue Violet", Color32.rgb(138, 43, 226)}, {"Lavender", Color32.rgb(230, 230, 250)},
      {"Orchid", Color32.rgb(218, 112, 214)},    {"Plum", Color32.rgb(221, 160, 221)},
    }

    def self.color_name(color : Color32) : String
      COLOR_NAMES.min_by do |_, c|
        dr = color.r.to_i32 - c.r.to_i32
        dg = color.g.to_i32 - c.g.to_i32
        db = color.b.to_i32 - c.b.to_i32
        dr * dr + dg * dg + db * db
      end[0]
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

    # One 64x1 texture: white with a straight-alpha ramp 0→255
    # (cached). The picker draws it tinted with the current RGB, so the
    # ramp itself is color-independent and never re-created.
    private def alpha_texture(ctx : Context) : UInt64
      key = "color_picker/alpha"
      if (cached = ctx.memory.texture_cache[key]?) && !cached.zero?
        return cached
      end

      data = Bytes.new(HUE_W * 4)
      HUE_W.times do |x|
        i = x * 4
        data[i] = 255_u8
        data[i + 1] = 255_u8
        data[i + 2] = 255_u8
        data[i + 3] = (x.to_f64 / (HUE_W - 1) * 255.0).round.to_u8
      end
      id = ctx.textures.register_rgba(HUE_W, 1, data)
      ctx.memory.texture_cache[key] = id unless id.zero?
      id
    end

    # Alternating gray squares behind semi-transparent fills (upstream
    # `paint_checkerboard`) — the alpha bar and the swatch use it so the
    # transparency is visible.
    private def paint_checkerboard(painter : Painter, rect : Rect) : Nil
      cell = 8.0
      light = Color32.rgb(152, 152, 152)
      dark = Color32.rgb(96, 96, 96)
      row = 0
      y = rect.top
      while y < rect.bottom
        col = 0
        x = rect.left
        while x < rect.right
          color = (row + col).even? ? light : dark
          w = {cell, rect.right - x}.min
          h = {cell, rect.bottom - y}.min
          painter.rect(Rect.from_min_size(Pos2.new(x, y), Vec2.new(w, h)),
            0.0, fill: color)
          x += cell
          col += 1
        end
        y += cell
        row += 1
      end
    end
  end
end
