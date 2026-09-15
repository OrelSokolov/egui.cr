# System port Fonts: candidate system font files for the default UI
# font, best-first. Pure platform data — the list is selected at compile
# time (win32 / darwin / everything else reads as Linux/BSD), no native
# calls needed, so the port stays headless-testable.
#
# The backend (backend/sokol.cr) feeds these to its font backends
# (FreetypeFonts → LightHintedFonts); the first file that loads wins.
# Apps can pass their own bundled font before falling back to these.

module Egui
  module SystemPorts
    module Fonts
      # Candidate font files, best-first (plain .ttf — both backends
      # load a single face, not .ttc collections).
      def self.search_paths : Array(String)
        {% if flag?(:win32) %}
          [
            "C:\\Windows\\Fonts\\segoeui.ttf",  # Segoe UI — the system font
            "C:\\Windows\\Fonts\\arial.ttf",
            "C:\\Windows\\Fonts\\tahoma.ttf",
          ]
        {% elsif flag?(:darwin) %}
          [
            "/System/Library/Fonts/SFNS.ttf",                  # San Francisco
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Arial.ttf",
          ]
        {% else %}
          [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
            "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
          ]
        {% end %}
      end
    end
  end
end
