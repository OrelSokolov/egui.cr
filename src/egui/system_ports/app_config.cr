# System port AppConfig: where an app persists its settings — named
# JSON files in the user's config directory, addressed by app name +
# config key so every app shares one storage scheme instead of
# re-implementing platform adapters per module (that is what
# Terminal::ConfigStore used to do):
#
#   Linux/BSD  $XDG_CONFIG_HOME/<app>/<name>.json (default ~/.config/…)
#   macOS      ~/Library/Application Support/<app>/<name>.json
#   Windows    %APPDATA%\<app>\<name>.json (roaming)
#
# The base dir comes from UserDirs (one platform mapping, shared).
#
#   settings = AppConfig.load("notepad", Settings.new)
#   settings.theme = "light"
#   AppConfig.save("notepad", settings)
#
# WHAT is in the file is the app's `JSON::Serializable` type; a missing
# file or corrupt JSON yields the default passed to #load, and #save is
# best effort — a bad settings dir must never keep an app from running.
# `use` swaps the base directory (specs inject a temp dir).

require "json"
require "file_utils"

module Egui
  module SystemPorts
    module AppConfig
      # Base-dir override for tests; nil = the platform user config
      # directory (UserDirs.config).
      @@base_dir : String? = nil

      # Redirect all configs into `base_dir` (specs inject a temp dir;
      # pass nil to return to the platform directory).
      def self.use(base_dir : String?) : Nil
        @@base_dir = base_dir
      end

      # The directory holding an app's config files.
      def self.dir(app : String) : String
        File.join(@@base_dir || UserDirs.config, app)
      end

      # The file for one config of an app — "settings" becomes
      # settings.json (a name already ending in .json is kept as is).
      def self.path(app : String, name : String = "settings") : String
        file = name.ends_with?(".json") ? name : "#{name}.json"
        File.join(dir(app), file)
      end

      # Read a config by key, parsed as `default`'s type (a
      # `JSON::Serializable`); a missing file or corrupt JSON yields
      # `default` — a bad settings file never keeps the app booting.
      def self.load(app : String, default : T,
                    name : String = "settings") : T forall T
        file = path(app, name)
        return default unless File.exists?(file)
        T.from_json(File.read(file))
      rescue JSON::Error | File::Error | IO::Error
        default
      end

      # Persist a config by key (its directory is created on demand).
      # Best effort: on IO errors the app keeps running with the
      # in-memory settings.
      def self.save(app : String, config : T,
                    name : String = "settings") : Nil forall T
        file = path(app, name)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, config.to_json)
      rescue File::Error
      end
    end
  end
end
