# System ports OpenUrl / RevealInFolder: hand a URL or a file to the OS —
# "open in the default browser" and "show in the file manager" (the
# egui `ui.link` / eframe `reveal` equivalents).
#
# Windows calls `ShellExecuteW` (shell32) directly — the documented way
# to launch a URL or folder with the default handler. Linux/BSD shells
# out to `xdg-open`, macOS to `open` / `open -R`. The call blocks only
# for the launcher itself, not for the app it spawns.

module Egui
  module SystemPorts
    {% if flag?(:win32) %}
      @[Link("shell32")]
      lib LibShellExecute
        # hwnd, verb, file, params, dir, show → HINSTANCE (> 32 = OK).
        fun ShellExecuteW(hwnd : Void*, verb : UInt16*, file : UInt16*,
                          params : UInt16*, dir : UInt16*, show_cmd : Int32) : Void*
      end
    {% end %}

    module OpenUrl
      # Open `url` (http/https) in the default browser. False when no
      # launcher is available or it refused the URL.
      def self.show(url : String) : Bool
        {% if flag?(:win32) %}
          Shell.execute("open", url)
        {% elsif flag?(:darwin) %}
          return false unless Dialogs.which("open")
          Dialogs.run?("open", [url])
        {% else %}
          return false unless Dialogs.which("xdg-open")
          Dialogs.run?("xdg-open", [url])
        {% end %}
      end
    end

    module RevealInFolder
      # Reveal `path` (file or directory) in the system file manager.
      def self.show(path : String) : Bool
        {% if flag?(:win32) %}
          Shell.execute("open", File.dirname(File.expand_path(path)))
        {% elsif flag?(:darwin) %}
          return false unless Dialogs.which("open")
          Dialogs.run?("open", ["-R", File.expand_path(path)])
        {% else %}
          return false unless Dialogs.which("xdg-open")
          Dialogs.run?("xdg-open", [File.dirname(File.expand_path(path))])
        {% end %}
      end
    end

    # Win32 launcher shared by OpenUrl / RevealInFolder.
    module Shell
      {% if flag?(:win32) %}
        SW_SHOWNORMAL = 1

        # `ShellExecuteW` returns an HINSTANCE cast; values ≤ 32 are
        # error codes, anything above means the handler launched.
        def self.execute(verb : String, target : String) : Bool
          result = LibShellExecute.ShellExecuteW(
            nil, verb.to_utf16, target.to_utf16,
            Pointer(UInt16).null, Pointer(UInt16).null, SW_SHOWNORMAL)
          result.address > 32
        end
      {% end %}
    end
  end
end
