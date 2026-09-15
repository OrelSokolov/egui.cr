# System ports OpenUrl / RevealInFolder: hand a URL or a file to the OS —
# "open in the default browser" and "show in the file manager" (the
# egui `ui.link` / eframe `reveal` equivalents).
#
# Same subprocess pattern as the dialog ports: `xdg-open` on Linux/BSD;
# other platforms are not wired yet (`show` returns false). The call
# blocks only for the launcher itself, not for the app it spawns.

module Egui
  module SystemPorts
    module OpenUrl
      # Open `url` (http/https) in the default browser. False when no
      # launcher is available or it refused the URL.
      def self.show(url : String) : Bool
        return false unless {{ flag?(:unix) }}
        return false unless Dialogs.which("xdg-open")
        Dialogs.run?("xdg-open", [url])
      end
    end

    module RevealInFolder
      # Reveal `path` (file or directory) in the system file manager.
      def self.show(path : String) : Bool
        return false unless {{ flag?(:unix) }}
        return false unless Dialogs.which("xdg-open")
        Dialogs.run?("xdg-open", [File.dirname(File.expand_path(path))])
      end
    end
  end
end
