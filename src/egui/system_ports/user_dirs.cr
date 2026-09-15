# System port UserDirs: where an app should persist its state — home
# plus the per-platform base dirs. Linux/BSD reads the XDG base
# directory spec straight from the environment (defaults ~/.config,
# ~/.local/share, ~/.cache) and goes through `xdg-user-dir` for
# `documents` &c.; macOS uses the Library layout (~/Library/Application
# Support, ~/Library/Caches) and the fixed home subfolders.

module Egui
  module SystemPorts
    module UserDirs
      # The user's home directory (fallback: the working directory).
      def self.home : String
        ENV["HOME"]? || Dir.current
      end

      # User-specific configuration: $XDG_CONFIG_HOME (default
      # ~/.config) on Linux/BSD; ~/Library/Application Support on macOS.
      def self.config : String
        {% if flag?(:darwin) %}
          File.join(home, "Library/Application Support")
        {% else %}
          xdg_path("XDG_CONFIG_HOME", ".config")
        {% end %}
      end

      # User-specific data: $XDG_DATA_HOME (default ~/.local/share) on
      # Linux/BSD; ~/Library/Application Support on macOS.
      def self.data : String
        {% if flag?(:darwin) %}
          File.join(home, "Library/Application Support")
        {% else %}
          xdg_path("XDG_DATA_HOME", ".local/share")
        {% end %}
      end

      # User-specific non-essential cache: $XDG_CACHE_HOME (default
      # ~/.cache) on Linux/BSD; ~/Library/Caches on macOS.
      def self.cache : String
        {% if flag?(:darwin) %}
          File.join(home, "Library/Caches")
        {% else %}
          xdg_path("XDG_CACHE_HOME", ".cache")
        {% end %}
      end

      # An XDG user dir by its `xdg-user-dir` name ("DOCUMENTS",
      # "DOWNLOADS", "PICTURES", …), or nil when not available. macOS:
      # the fixed home subfolder (Documents, Downloads, …), only when
      # it exists.
      def self.user_dir(name : String) : String?
        {% if flag?(:darwin) %}
          folder = {"DESKTOP"   => "Desktop",
                    "DOCUMENTS" => "Documents",
                    "DOWNLOADS" => "Downloads",
                    "MUSIC"     => "Music",
                    "PICTURES"  => "Pictures",
                    "VIDEOS"    => "Movies"}[name]? || name
          dir = File.join(home, folder)
          Dir.exists?(dir) ? dir : nil
        {% else %}
          return nil unless {{ flag?(:unix) }}
          Dialogs.run("xdg-user-dir", [name])
        {% end %}
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
