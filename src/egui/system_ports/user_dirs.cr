# System port UserDirs: where an app should persist its state.
#
# Linux/BSD reads home ($HOME) plus the XDG base dirs (config/data/
# cache) straight from the environment, and resolves `documents` &c.
# through `xdg-user-dir`. Windows uses %USERPROFILE% / %APPDATA% (roaming
# config) / %LOCALAPPDATA% (local data; cache is a "cache" subfolder —
# the Electron convention), and resolves known folders (Documents,
# Downloads, Pictures) through `SHGetKnownFolderPath` (shell32).

module Egui
  module SystemPorts
    module UserDirs
      {% if flag?(:win32) %}
        # Known-folder GUIDs for the `user_dir` names.
        KNOWN_FOLDERS = {
          "DOCUMENTS" => "FDD39AD0-238F-46AF-ADB4-6C85480369C7",
          "DOWNLOADS" => "374DE290-123F-4565-9164-39C4925E467B",
          "PICTURES"  => "33E28130-4E1E-4676-835A-98395C3BC3BB",
        }

        @@known_cache = {} of String => String?
      {% end %}

      # The user's home directory (fallback: the working directory).
      def self.home : String
        {% if flag?(:win32) %}
          ENV["USERPROFILE"]? || Dir.current
        {% else %}
          ENV["HOME"]? || Dir.current
        {% end %}
      end

      # User-specific configuration (%APPDATA% / $XDG_CONFIG_HOME,
      # default ~/.config).
      def self.config : String
        {% if flag?(:win32) %}
          ENV["APPDATA"]? || home
        {% else %}
          xdg_path("XDG_CONFIG_HOME", ".config")
        {% end %}
      end

      # User-specific data (%LOCALAPPDATA% / $XDG_DATA_HOME, default
      # ~/.local/share).
      def self.data : String
        {% if flag?(:win32) %}
          ENV["LOCALAPPDATA"]? || config
        {% else %}
          xdg_path("XDG_DATA_HOME", ".local/share")
        {% end %}
      end

      # User-specific non-essential cache (%LOCALAPPDATA%\cache /
      # $XDG_CACHE_HOME, default ~/.cache).
      def self.cache : String
        {% if flag?(:win32) %}
          File.join(data, "cache")
        {% else %}
          xdg_path("XDG_CACHE_HOME", ".cache")
        {% end %}
      end

      # A known/XDG user dir by its name ("DOCUMENTS", "DOWNLOADS",
      # "PICTURES", …), or nil when not available. Results are cached.
      def self.user_dir(name : String) : String?
        {% if flag?(:win32) %}
          guid = KNOWN_FOLDERS[name]?
          return nil unless guid
          @@known_cache[name] ||= known_folder(guid)
        {% else %}
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

      {% if flag?(:win32) %}
        protected def self.known_folder(guid : String) : String?
          bytes = guid_bytes(guid)
          return nil unless bytes
          out_path = Pointer(UInt16).null
          hr = LibC.SHGetKnownFolderPath(bytes.to_unsafe.as(LibC::GUID*),
            0_u32, Pointer(Void).null, pointerof(out_path).as(LibC::LPWSTR*))
          return nil unless hr.zero? && !out_path.null?
          len = 0
          while out_path[len] != 0
            len += 1
          end
          result = String.from_utf16(Slice.new(out_path, len))
          LibC.CoTaskMemFree(out_path.as(Void*))
          result
        rescue
          nil
        end

        # RFC-4122 GUID string ("FDD39AD0-238F-...") → 16 bytes in the
        # Windows GUID struct layout (first fields little-endian).
        protected def self.guid_bytes(guid : String) : Bytes?
          parts = guid.split('-')
          return nil unless parts.size == 5
          d1 = parts[0].to_u32?(16) # may exceed Int32 (e.g. FDD39AD0)
          d2 = parts[1].to_i32?(16)
          d3 = parts[2].to_i32?(16)
          rest = parts[3] + parts[4]
          return nil unless d1 && d2 && d3 && rest.size == 16
          tail = [] of UInt8
          8.times do |i|
            byte = rest[i*2, 2].to_i32?(16)
            return nil unless byte
            tail << byte.to_u8!
          end
          Bytes.new(16).tap do |b|
            b[0] = (d1 & 0xFF).to_u8!
            b[1] = ((d1 >> 8) & 0xFF).to_u8!
            b[2] = ((d1 >> 16) & 0xFF).to_u8!
            b[3] = ((d1 >> 24) & 0xFF).to_u8!
            b[4] = (d2 & 0xFF).to_u8!
            b[5] = ((d2 >> 8) & 0xFF).to_u8!
            b[6] = (d3 & 0xFF).to_u8!
            b[7] = ((d3 >> 8) & 0xFF).to_u8!
            8.times { |i| b[8 + i] = tail[i] }
          end
        end
      {% end %}

      private def self.xdg_path(env_var : String, fallback : String) : String
        value = ENV[env_var]?
        return value if value && !value.empty?
        File.join(home, fallback)
      end
    end
  end
end
