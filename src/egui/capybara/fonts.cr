# Optional Capybara font leg: real glyphs in headless screenshots.
#
# Requires the pure-Crystal font backend (freetype-cr → CrystalFonts) and
# installs it into a Context, then hooks `Raster`'s text renderer so
# TextCmds composite through the same glyph atlas the sokol backend walks
# (one `Fonts#walk` per command; coverage straight out of the CPU-side
# atlas — see backend/text.cr). Without this file, screenshots still
# render shapes but text shows as extent boxes.
#
#   require "egui/capybara"
#   require "egui/capybara/fonts"
#   Egui::Capybara::Fonts.install!(ctx)

require "../backend/crystalfonts"

module Egui
  module Capybara
    module Fonts
      # Repo-bundled faces (assets/fonts) — deterministic across machines,
      # preferred over whatever the system scan would pick.
      def self.bundled_paths : Array(String)
        dir = File.expand_path("../../../assets/fonts", __DIR__)
        ["#{dir}/NotoSans-Regular.ttf", "#{dir}/LiberationMono-Regular.ttf"]
      end

      # Install primary (+ optional mono) stacks and the Raster text
      # renderer. `paths` defaults to the bundled Noto Sans; pass
      # `SystemPorts::Fonts.search_paths` to match a live app instead.
      def self.install!(ctx : Egui::Context,
                        paths : Array(String)? = nil,
                        mono_paths : Array(String)? = nil) : Nil
        paths ||= bundled_paths
        font = Egui::Backend::CrystalFonts.from_system(paths)
        ctx.fonts = font if font
        if mono_paths
          mono = Egui::Backend::CrystalFonts.from_system(mono_paths)
          ctx.mono_fonts = mono if mono
        end

        Egui::Capybara::Raster.text_renderer = ->(cmd : TextCmd,
          raster : Egui::Capybara::Raster) do
          raster.draw_atlas_text(cmd, ctx)
        end
      end

      # Convenience for Sessions/suites: install into the app's context.
      def self.install_for!(app : Egui::App, **opts) : Nil
        install!(app.ctx, **opts)
      end
    end
  end
end

# The atlas compositor, re-opened onto Raster (kept out of the core
# rasterizer: Backend::AtlasFonts only exists when a font backend is
# required).
class Egui::Capybara::Raster
  def draw_atlas_text(cmd : Egui::TextCmd, ctx : Egui::Context) : Nil
    fonts = ctx.fonts_for(cmd.family, cmd.bold?, cmd.italic?)
    return unless fonts.is_a?(Egui::Backend::AtlasFonts) && fonts.loaded?
    af = fonts.as(Egui::Backend::AtlasFonts)

    # Same anchoring as the sokol backend (paint_text) at 1×: pos is the
    # left-center of the text box, baseline via ascender/descender,
    # rounded pen + baseline (egui pixel snapping).
    asc, desc = af.metrics_at(cmd.size)
    baseline = (cmd.pos.y + (asc + desc) / 2.0).round
    atlas = af.atlas
    x_origin = cmd.pos.x
    af.walk(cmd.text, cmd.size) do |pen, g|
      next if g.w == 0 || g.h == 0
      x0 = (x_origin + pen + g.xoff).round.to_i
      y0 = (baseline - g.ytop).round.to_i
      cov = atlas.debug_region(g)
      h = g.h
      w = g.w
      h.times do |row|
        y = y0 + row
        next if y < 0 || y >= height
        w.times do |col|
          x = x0 + col
          next if x < 0 || x >= width
          a = cov[row * w + col].to_f64 / 255.0
          next if a <= 0.0
          blend_px(x, y, cmd.color, a, cmd.clip)
        end
      end
    end
  end
end
