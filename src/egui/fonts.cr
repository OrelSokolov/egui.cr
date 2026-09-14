# egui's font/text-measurement seam (fonts.rs upstream): the core needs
# `measure` to size widgets; the backend installs a real font
# (fontstash) while specs run headless with the monospace estimate.

module Egui
  abstract class Fonts
    # Estimated line height as a font-size factor (matches MonospaceFonts;
    # used by containers that need a row height before measuring).
    LINE_H_FACTOR = 1.3

    abstract def measure(text : String, size : Float64) : Vec2
  end

  # Headless fallback: fixed-ratio monospace metrics. Deterministic —
  # specs rely on layout being identical across frames.
  class MonospaceFonts < Fonts
    CHAR_W = 0.6
    LINE_H = LINE_H_FACTOR

    def measure(text : String, size : Float64) : Vec2
      lines = text.count('\n') + 1
      widest = text.split('\n').map(&.size).max? || 0
      Vec2.new(widest * size * CHAR_W, lines * size * LINE_H)
    end
  end
end
