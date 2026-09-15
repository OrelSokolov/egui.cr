# System port UserDirs: where an app should persist its state — home
# plus the XDG base dirs (config/data/cache), read straight from the
# environment (XDG base directory spec defaults). `documents` &c. go
# through `xdg-user-dir` when installed (XDG user dirs).

module Egui
  module SystemPorts
    module UserDirs
      # The user's home directory (fallback: the working directory).
      def self.home : String
        ENV["HOME"]? || Dir.current
      end

      # User-specific configuration ($XDG_CONFIG_HOME, default ~/.config).
      def self.config : String
        xdg_path("XDG_CONFIG_HOME", ".config")
      end

      # User-specific data ($XDG_DATA_HOME, default ~/.local/share).
      def self.data : String
        xdg_path("XDG_DATA_HOME", ".local/share")
      end

      # User-specific non-essential cache ($XDG_CACHE_HOME, default ~/.cache).
      def self.cache : String
        xdg_path("XDG_CACHE_HOME", ".cache")
      end

      # An XDG user dir by its `xdg-user-dir` name ("DOCUMENTS",
      # "DOWNLOADS", "PICTURES", …), or nil when not available.
      def self.user_dir(name : String) : String?
        return nil unless {{ flag?(:unix) }}
        Dialogs.run("xdg-user-dir", [name])
      end

      def self.documents : String?
        user_dir("DOCUMENTS")
      end

      def self.downloads : String?
        user_dir("DOWNLOADS")
      end

      def self.pictures : String?
        user_dir("PICTURES")
      end

      private def self.xdg_path(env_var : String, fallback : String) : String
        value = ENV[env_var]?
        return value if value && !value.empty?
        File.join(home, fallback)
      end
    end
  end
end
