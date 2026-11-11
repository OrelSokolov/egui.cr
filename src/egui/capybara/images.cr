# Optional Capybara image leg: real pixels in headless screenshots.
#
# Composites ImageCmds through the Context's TextureRegistry pixel
# backup (DummyTextureRegistry keeps the uploaded RGBA bytes; the GPU
# backend keeps none) — bilinear sampling of the cmd's uv window with
# its tint (nearest when the cmd asks for point sampling), src-over
# like every other primitive. Without this file ImageCmds draw the
# checker placeholder.
#
# This leg only RASTERIZES already-uploaded textures; decoding image
# FILES stays the ImageCodec seam's business — install a provider
# alongside (the sokol backend's StbImageCodec when the shim is
# linked) or `Context#load_image` keeps answering 0:
#
#   require "egui/capybara"
#   require "egui/capybara/images"
#   Egui::Capybara::Images.install!(ctx)

module Egui
  module Capybara
    module Images
      # Hook `Raster`'s image renderer onto `ctx`'s texture registry.
      def self.install!(ctx : Egui::Context) : Nil
        Egui::Capybara::Raster.image_renderer = ->(cmd : ImageCmd,
          raster : Egui::Capybara::Raster) do
          raster.draw_texture(cmd, ctx)
        end
      end

      # Convenience for Sessions/suites: install into the app's context.
      def self.install_for!(app : Egui::App) : Nil
        install!(app.ctx)
      end
    end
  end
end

# The texture compositor, re-opened onto Raster (kept out of the core
# rasterizer: it needs the live Context's TextureRegistry).
class Egui::Capybara::Raster
  def draw_texture(cmd : Egui::ImageCmd, ctx : Egui::Context) : Nil
    tw, th, rgba = begin
      ctx.textures.pixels(cmd.texture_id) ||
        (return placeholder_image(cmd))
    end

    r = cmd.rect
    return if r.width <= 0.0 || r.height <= 0.0
    tint = cmd.tint
    tinted = tint.r != 255 || tint.g != 255 || tint.b != 255 ||
             tint.a != 255

    (r.top.to_i...r.bottom.to_i).each do |y|
      (r.left.to_i...r.right.to_i).each do |x|
        # screen → uv window (0..1) → texture space
        u = (x + 0.5 - r.min.x) / r.width
        v = (y + 0.5 - r.min.y) / r.height
        cr, cg, cb, ca = sample(rgba, tw, th, cmd, u, v)
        next if ca <= 0
        if tinted
          cr = cr * tint.r // 255
          cg = cg * tint.g // 255
          cb = cb * tint.b // 255
          ca = ca * tint.a // 255
          next if ca <= 0
        end
        blend_px(x, y, Egui::Color32.rgba(cr, cg, cb, ca),
          ca.to_f64 / 255.0, cmd.clip, corners: cmd.clip_corners)
      end
    end
  end

  # One texel pull, point-sampled (`nearest` — pixel-art) or bilinear
  # over straight-alpha rgba (the GPU default). Coordinates are clamped
  # at the edges like a sampler with CLAMP_TO_EDGE.
  private def sample(rgba : Bytes, tw : Int32, th : Int32,
                     cmd : Egui::ImageCmd, u : Float64, v : Float64)
    fu = (cmd.uv.min.x + u * cmd.uv.width) * tw - 0.5
    fv = (cmd.uv.min.y + v * cmd.uv.height) * th - 0.5
    if cmd.nearest?
      x = fu.round.clamp(0.0, (tw - 1).to_f64).to_i
      y = fv.round.clamp(0.0, (th - 1).to_f64).to_i
      i = (y * tw + x) * 4
      return rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]
    end

    x0 = fu.floor.to_i
    y0 = fv.floor.to_i
    fx = fu - x0
    fy = fv - y0
    x0 = x0.clamp(0, tw - 1); x1 = (x0 + 1).clamp(0, tw - 1)
    y0 = y0.clamp(0, th - 1); y1 = (y0 + 1).clamp(0, th - 1)
    i00 = (y0 * tw + x0) * 4; i10 = (y0 * tw + x1) * 4
    i01 = (y1 * tw + x0) * 4; i11 = (y1 * tw + x1) * 4

    out = StaticArray(Int32, 4).new(0)
    4.times do |c|
      # Int32 math: channel deltas go both ways, UInt8 - UInt8 underflows
      top = rgba[i00 + c].to_i32 +
        ((rgba[i10 + c].to_i32 - rgba[i00 + c].to_i32) * fx).round.to_i
      bot = rgba[i01 + c].to_i32 +
        ((rgba[i11 + c].to_i32 - rgba[i01 + c].to_i32) * fx).round.to_i
      out[c] = top + ((bot - top) * fy).round.to_i
    end
    {out[0], out[1], out[2], out[3]}
  end
end
