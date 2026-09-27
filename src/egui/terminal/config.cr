# egui-terminal config: user profiles persisted as JSON, cross-platform
# through a config PORT (the SystemPorts pattern, kept inside the
# terminal module so the emulator core stays self-contained).
#
# WHERE the file lives is the port — one adapter per platform:
#
#   Linux/BSD  $XDG_CONFIG_HOME/egui-terminal/settings.json
#              (default ~/.config/egui-terminal/…)
#   macOS      ~/Library/Application Support/egui-terminal/settings.json
#   Windows    %APPDATA%\egui-terminal\settings.json (roaming)
#
# WHAT is in the file is plain JSON data (Profile below):
#
#   {
#     "active": "default",
#     "profiles": {
#       "default": {
#         "opacity": 0.9,
#         "background": "#16161e",
#         "cursor_blinks": true
#       }
#     }
#   }

require "json"
require "file_utils"

module Egui
  module Terminal
    # One saved terminal look: terminal background opacity, background
    # color and the cursor-blink switch. A missing key in the JSON
    # keeps the default, so older files load into newer code unchanged.
    class Profile
      include JSON::Serializable

      # Terminal background opacity, 1.0 = opaque. Below 1.0 the app
      # (see examples/terminal.cr) runs a per-pixel-transparent window
      # and paints the terminal background with this alpha — the
      # desktop shows through the grid only, UI panels stay opaque
      # (alacritty's background_opacity).
      property opacity : Float64 = 1.0
      # Terminal background color, "#rrggbb".
      property background : String = Theme::DEFAULT_BG_HEX
      # Blinking cursor (TermView's cursor_blinks) — off means a steady
      # cursor (and no repaints of its own).
      property cursor_blinks : Bool = false

      def initialize(@opacity : Float64 = 1.0,
                     @background : String = Theme::DEFAULT_BG_HEX,
                     @cursor_blinks : Bool = false)
      end

      # The saved background as an opaque Color32 (the terminal-
      # background opacity from #opacity becomes its alpha — the app
      # composes that in, see TermView's replace rect).
      def background_color : Color32
        hex = @background
        hex = hex[1..] if hex.starts_with?('#')
        if hex.size == 6 &&
           (r = hex[0, 2].to_i?(16)) && (g = hex[2, 2].to_i?(16)) &&
           (b = hex[4, 2].to_i?(16))
          Color32.rgb(r, g, b)
        else
          Theme.new.background
        end
      end

      def background_color=(color : Color32) : Nil
        @background = "#%02x%02x%02x" % {color.r, color.g, color.b}
      end
    end

    # The config-location port: WHICH directory the settings file lives
    # in, per platform. `use` swaps the adapter (specs inject a temp
    # dir); `path` is the default file the app loads/saves.
    module ConfigStore
      abstract class Adapter
        # The directory holding the settings file (existing or not).
        abstract def config_dir : String

        # The settings file path inside #config_dir.
        def path : String
          File.join(config_dir, "settings.json")
        end
      end

      # Linux/BSD: the XDG base directory spec, straight from the
      # environment ($XDG_CONFIG_HOME, default ~/.config).
      class LinuxAdapter < Adapter
        def config_dir : String
          base = ENV["XDG_CONFIG_HOME"]?
          base = File.join(ENV["HOME"]? || Dir.current, ".config") if base.nil? || base.empty?
          File.join(base, "egui-terminal")
        end
      end

      # macOS: the Application Support layout.
      class MacAdapter < Adapter
        def config_dir : String
          File.join(ENV["HOME"]? || Dir.current,
            "Library/Application Support/egui-terminal")
        end
      end

      # Windows: %APPDATA% (roaming — settings follow the user), with
      # %USERPROFILE% as a fallback.
      class WindowsAdapter < Adapter
        def config_dir : String
          base = ENV["APPDATA"]? || ENV["USERPROFILE"]? || Dir.current
          File.join(base, "egui-terminal")
        end
      end

      @@adapter : Adapter = {% if flag?(:win32) %}
                              WindowsAdapter.new
                            {% elsif flag?(:darwin) %}
                              MacAdapter.new
                            {% else %}
                              LinuxAdapter.new
                            {% end %}

      # The active adapter (the platform one unless #use replaced it).
      def self.adapter : Adapter
        @@adapter
      end

      # Install a custom adapter (specs point it at a temp dir).
      def self.use(adapter : Adapter) : Nil
        @@adapter = adapter
      end

      # The settings file path through the active adapter.
      def self.path : String
        @@adapter.path
      end
    end

    # The whole settings file: named profiles plus which one is active.
    class Config
      include JSON::Serializable

      property active : String = "default"
      property profiles : Hash(String, Profile) = {"default" => Profile.new}

      def initialize(@active : String = "default",
                     @profiles : Hash(String, Profile) = {"default" => Profile.new})
      end

      # Load from `path` (the platform store by default). A missing file
      # or corrupt JSON yields the defaults — a bad settings file must
      # never keep the terminal from booting.
      def self.load(path : String = ConfigStore.path) : Config
        return new unless File.exists?(path)
        from_json(File.read(path))
      rescue JSON::Error
        new
      end

      # The selected profile, falling back to any survivor (a stale
      # "active" name, or an emptied file).
      def active_profile : Profile
        profiles[@active]? || profiles.first_value? || Profile.new
      end

      # Persist to `path` (the platform store by default). Best effort:
      # on IO errors the app keeps running with the in-memory settings.
      def save(path : String = ConfigStore.path) : Nil
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, to_json)
      rescue File::Error
      end
    end
  end
end
