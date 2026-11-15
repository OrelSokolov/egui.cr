# <formula> — the exml tag for LaTeX formulas, typeset by mathjax.cr
# (the Crystal port of the MathJax v3 core) and baked into a texture
# by the stock Svg widget through the pure-Crystal NanoSVG port — the
# same pipeline as examples/formulas.cr, one code path with the icons.
#
# OPT-IN require: mathjax is a development dependency of the shard
# (examples/specs only), so this file is NOT pulled in by `require
# "egui"`. Apps that want the tag require it explicitly:
#
#   require "egui"
#   require "egui/exml_formula"
#
# Markup:
#
#   <formula tex="\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"/>
#   <formula tex="{state/tex}" size="30" color="#1a1a2e"/>
#   <formula tex="e^{i\pi}" display="false"/>
#
#   tex      required; interpolated against the store ({…} slots)
#   size     px per em, default 22 (interpolated — a bound slider
#            rebakes the Svg raster cache, nothing else)
#   display  display vs inline TeX mode, default true ("false"/"0"/
#            "no"/"inline" switch to inline)
#   color    ink as #rgb/#rrggbb/#rrggbbaa; default: the theme's text
#            color (the Svg resolves currentColor into it)
#
# Typesetting runs ONCE per (tex, display) — the v3 path SVG rides in
# a bounded FIFO cache, so every frame is just the Svg quad replay.
# A TeX parse error renders as a plain error label, never a raise.

require "mathjax"
require "../egui"

module Egui
  module ExmlFormula
    # One typeset formula: the v3 SVG (glyph outline paths in <defs> +
    # <use>, no font files) plus its natural size in em.
    class Entry
      getter svg : String
      getter width_em : Float64
      getter height_em : Float64
      getter error : String?

      def initialize(@tex : String, @display : Bool)
        @svg = ""
        @width_em = 0.0
        @height_em = 0.0
        @error = nil
        begin
          @svg = MathJax.to_svg(@tex, display: @display, paths: true)
          # width/height attrs are in ex (1 em = 2 ex at the renderer's
          # em:16/ex:8 reference)
          @width_em = attr_em("width")
          @height_em = attr_em("height")
        rescue ex : MathJax::TeX::TexError
          @error = ex.message.to_s
        end
      end

      private def attr_em(name : String) : Float64
        if (v = @svg.match(/#{name}="([\d.]+)ex"/))
          v[1].to_f / 2.0
        else
          0.0
        end
      end
    end

    # Bounded FIFO, the Svg raster-cache eviction model: a screenful
    # of distinct formulas stays hot, a scrolling feed of new ones
    # evicts the oldest instead of growing forever.
    MAX_CACHE = 256

    @@cache = {} of {String, Bool} => Entry
    @@order = [] of {String, Bool}

    def self.typeset(tex : String, display : Bool) : Entry
      key = {tex, display}
      if (hit = @@cache[key]?)
        return hit
      end
      entry = Entry.new(tex, display)
      @@cache[key] = entry
      @@order << key
      if @@order.size > MAX_CACHE
        @@cache.delete(@@order.shift)
      end
      entry
    end

    # #rgb/#rrggbb/#rrggbbaa → Color32, or nil for the caller's theme
    # default (the ecss parser is private to styles; three lines here
    # beat widening that surface for one attribute).
    def self.parse_color(s : String) : Color32?
      return nil unless s.starts_with?('#')
      hex = s[1..]
      hex = hex.chars.map { |c| "#{c}#{c}" }.join if hex.size == 3
      return nil unless hex.size == 6 || hex.size == 8
      pairs = (0...hex.size).step(2).map { |i| hex[i, 2].to_u8?(16) }.to_a
      return nil unless pairs.all?(&.is_a?(UInt8))
      r, g, b = pairs[0].as(UInt8), pairs[1].as(UInt8), pairs[2].as(UInt8)
      a = hex.size == 8 ? pairs[3].as(UInt8) : 255_u8
      Color32.new(r, g, b, a)
    rescue
      nil
    end

    DEFAULT_EM = 22.0
    INLINE_WORDS = {"false", "0", "no", "inline"}
  end
end

widget :formula do |node, ui, ctx, rt, r|
  tex = rt.interpolate(node.attrs["tex"]? || "")
  display = !Egui::ExmlFormula::INLINE_WORDS.includes?(
    rt.interpolate(node.attrs["display"]? || "true").downcase)
  entry = Egui::ExmlFormula.typeset(tex, display)
  if error = entry.error
    ui.label("formula parse error: #{error}")
    next
  end
  em = rt.interpolate(node.attrs["size"]? ||
                      "#{Egui::ExmlFormula::DEFAULT_EM}").to_f? ||
       Egui::ExmlFormula::DEFAULT_EM
  color = (c = node.attrs["color"]?) ?
    Egui::ExmlFormula.parse_color(rt.interpolate(c)) || ui.style.visuals.text_color :
    ui.style.visuals.text_color
  size = Egui::Vec2.new(entry.width_em * em, entry.height_em * em)
  rect = ui.allocate_at_least(size)
  Egui::Svg.new(entry.svg, size: size, current_color: color).paint(ui, rect)
end
