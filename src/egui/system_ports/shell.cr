# System ports OpenUrl / RevealInFolder / FileOpen: hand a URL or a
# file to the OS — "open in the default browser", "show in the file
# manager" (the egui `ui.link` / eframe `reveal` equivalents) and
# "open with the default application" (the double-click behavior).
#
# Windows calls `ShellExecuteW` (shell32) directly — the documented way
# to launch a URL or folder with the default handler. Linux/BSD shells
# out to `xdg-open`, macOS to `open` / `open -R`. Android resolves the
# URL through an ACTION_VIEW Intent (sysport JNI bridge); FileOpen and
# RevealInFolder would need content:// URIs through a FileProvider
# manifest declaration — not wired (returns false). iOS opens URLs
# through UIApplication (UIKit bridge); RevealInFolder/FileOpen have no
# iOS counterpart (no user-visible file manager for sandbox paths) —
# not wired (returns false). The call blocks only
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
        {% elsif flag?(:ios) %}
          Ios.open_url(url)
        {% elsif flag?(:darwin) %}
          return false unless Dialogs.which("open")
          Dialogs.run?("open", [url])
        {% elsif flag?(:android) %}
          Android.open_url(url)
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
          # `explorer /select,<path>` opens the folder AND highlights
          # the item (parity with macOS `open -R`). Explorer exits
          # immediately with a meaningless code — only the spawn counts.
          return false unless Dialogs.which("explorer")
          Dialogs.spawn("explorer", ["/select,#{File.expand_path(path)}"])
        {% elsif flag?(:ios) %}
          # No user-visible file manager exists for sandbox paths —
          # see the module comment.
          false
        {% elsif flag?(:darwin) %}
          return false unless Dialogs.which("open")
          Dialogs.run?("open", ["-R", File.expand_path(path)])
        {% elsif flag?(:android) %}
          # No ACTION_VIEW equivalent without a content:// URI — see the
          # module comment.
          false
        {% else %}
          return false unless Dialogs.which("xdg-open")
          Dialogs.run?("xdg-open", [File.dirname(File.expand_path(path))])
        {% end %}
      end
    end

    # Open `path` (file or directory) with its default OS application
    # — what a double click does. False when no launcher is available
    # or it refused the path.
    module FileOpen
      def self.show(path : String) : Bool
        path = File.expand_path(path)
        {% if flag?(:win32) %}
          Shell.execute("open", path)
        {% elsif flag?(:ios) %}
          # No default-app dispatch for sandbox files — see the module
          # comment.
          false
        {% elsif flag?(:darwin) %}
          return false unless Dialogs.which("open")
          Dialogs.run?("open", [path])
        {% elsif flag?(:android) %}
          # file:// URIs are blocked (FileUriExposedException) and a
          # FileProvider needs manifest + res/xml wiring — see the
          # module comment.
          false
        {% else %}
          return false unless Dialogs.which("xdg-open")
          Dialogs.run?("xdg-open", [path])
        {% end %}
      end
    end

    # Win32 launcher shared by OpenUrl / FileOpen / RevealInFolder.
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
