# Real font CUTS (weight axis) — the engine twin of the fontbrowser's
# filename parsing, promoted so the CSS `font_weight` cascade and the
# inspector's weight selector can resolve REAL faces instead of the
# boolean bold fallback.
#
# Noto-style families ship every weight as its own FILE
# ("NotoSans-Thin.ttf" … "NotoSans-Black.ttf"), and the SFNT `name`
# table of each registers as its own legacy family ("Noto Sans Thin").
# #normalize_family folds those back onto the base ("Noto Sans"), and
# #parse reads the post-dash filename token into a weight number plus
# slant — the Google Fonts axis ("Thin 100" … "Black 900 Italic").
#
# `Context#fonts_for_weight` turns (family, weight) into the cut's
# real stack (a "wght:<path>" deferred family, measure and draw share
# it); `Context#font_weight_axis` feeds the inspector's smart selector
# with the weights that actually exist for a family.

module Egui
  module FontCuts
    # One style file of a family: its slot on the weight axis.
    record Cut, weight : Int32, italic : Bool, label : String, known : Bool, path : String

    # Filename token → {prettified slot name, CSS weight}.
    WEIGHTS = {
      "thin"       => {"Thin", 100},
      "extralight" => {"ExtraLight", 200},
      "ultralight" => {"ExtraLight", 200},
      "light"      => {"Light", 300},
      ""           => {"Regular", 400},
      "regular"    => {"Regular", 400},
      "book"       => {"Regular", 400},
      "r"          => {"Regular", 400},
      "roman"      => {"Regular", 400},
      "medium"     => {"Medium", 500},
      "semibold"   => {"SemiBold", 600},
      "demibold"   => {"SemiBold", 600},
      "bold"       => {"Bold", 700},
      "extrabold"  => {"ExtraBold", 800},
      "ultrabold"  => {"ExtraBold", 800},
      "black"      => {"Black", 900},
      "heavy"      => {"Black", 900},
    }

    # Glued short codes ("Ubuntu-R.ttf") → long form before lookup.
    LONG_TOKENS = {
      "r"  => "regular", "b" => "bold", "i" => "italic", "bi" => "bold italic",
      "bd" => "bold", "it" => "italic", "z" => "bold italic",
    }

    # The CSS name of a ladder slot ("700" → "Bold").
    def self.weight_name(num : Int32) : String
      WEIGHTS.each_value do |name, w|
        return name if w == num
      end
      num.to_s
    end

    # The style segment of a font filename: after the last '-'
    # ("NotoSans-BoldItalic.ttf" → "BoldItalic", "Ubuntu-R.ttf" → "R");
    # no dash at all → "" (the whole base is the family name).
    def self.style_token(path : String) : String
      base = File.basename(path, ".ttf")
      base.includes?('-') ? base.rpartition('-').last : ""
    end

    # Parse the post-dash filename token into a Cut: "BoldItalic" →
    # Bold 700 Italic, "Italic" → Regular 400 Italic, "SemiBold" →
    # SemiBold 600 roman, "ExtraCondensedBold" → known: false (a width
    # shape, not a weight slot — it keeps its prettified token label).
    def self.parse(path : String) : Cut
      token = style_token(path)
      t = (LONG_TOKENS[token.downcase]? || token.downcase)
      slant = ""
      if t.ends_with?("italic")
        slant = "Italic"
        t = t.rpartition("italic").first
      elsif t.ends_with?("oblique")
        slant = "Oblique"
        t = t.rpartition("oblique").first
      end
      if (w = WEIGHTS[t]?)
        Cut.new(w[1], !slant.empty?,
          "#{w[0]} #{w[1]}#{slant.empty? ? "" : " #{slant}"}", true, path)
      else
        pretty = token.gsub(/(?<=[A-Za-z])(?=[A-Z])/, " ").capitalize
        Cut.new(10_000, !slant.empty?,
          pretty + (slant.empty? ? "" : " #{slant}"), false, path)
      end
    end

    # Trailing style words stripped off a legacy family name:
    # "Noto Sans Thin" → "Noto Sans"; width families ("Noto Sans
    # ExtraCondensed") stay their own family, like Google's. At least
    # one word always remains.
    STYLE_WORDS = %w[thin extralight ultralight light medium semibold
                     demibold bold extrabold ultrabold black heavy italic
                     oblique regular book roman]

    def self.normalize_family(name : String) : String
      words = name.split
      while words.size > 1 && STYLE_WORDS.includes?(words.last.downcase)
        words.pop
      end
      words.join(" ")
    end

    # One-time system scan (cached): normalized family name → every
    # loadable .ttf cut of that family, the weight axis first
    # (100→900, roman before slanted), unknown width/shape cuts after
    # it alphabetically. Pure `name`-table reads — no font parsing.
    @@installed : Hash(String, Array(Cut))?

    def self.installed : Hash(String, Array(Cut))
      @@installed ||= begin
        families = {} of String => Array(Cut)
        SystemPorts::Fonts.font_dirs.each do |dir|
          next unless Dir.exists?(dir)
          Dir.glob("#{dir}/**/*") do |path|
            next unless path.downcase.ends_with?(".ttf") && File.file?(path)
            name = SystemPorts::Fonts.family_name(path)
            next unless name
            (families[normalize_family(name)] ||= [] of Cut) << parse(path)
          end
        end
        families.each_value &.sort_by! { |c| {c.weight, c.italic ? 1 : 0, c.label} }
        families
      end
    end

    # The family's ROMAN weight axis — distinct weights, 100→900.
    # Empty when the family is unknown (nothing installed under it).
    def self.axis(family : String?) : Array(Int32)
      return [] of Int32 unless family
      cuts = installed[family]?
      return [] of Int32 unless cuts
      cuts.reject(&.italic).map(&.weight).uniq.sort
    end

    # CSS font matching (simplified): the exact slot when it exists,
    # else the NEAREST — ties break towards 400 (heavier side when the
    # target is above 400, lighter side below). Italic cuts never
    # match a roman target (the italic machinery owns slant).
    def self.closest(family : String?, target : Int32) : Cut?
      return nil unless family
      cuts = installed[family]?
      return nil unless cuts
      roman = cuts.reject(&.italic)
      return nil if roman.empty?
      roman.min_by do |c|
        diff = (c.weight - target).abs
        # Prefer the target's own side of 400 on a tie (CSS 400+ seeks
        # heavier, <400 seeks lighter): nudge opposite-side slots.
        wrong_side = target >= 400 ? c.weight < target : c.weight > target
        diff + (wrong_side && diff > 0 ? 0.5 : 0.0)
      end
    end

    # The deferred-stack family name for one cut file — unique per
    # path, can't collide with catalog family names.
    def self.stack_name(path : String) : String
      "wght:#{path}"
    end
  end
end
