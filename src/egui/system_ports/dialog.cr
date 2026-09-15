# System ports OpenFileDialog / SaveFileDialog: native file pickers.
#
# Linux/BSD shell out to `zenity` (GNOME &c) or `kdialog` (KDE), the
# common toolkit-free way to get a native dialog — no extra windowing
# dependency. Other platforms are not wired yet: `show` returns nil.
#
# The call blocks (the dialog is modal): invoked from `update`, the
# frame loop simply freezes until the user picks a file or cancels.

module Egui
  module SystemPorts
    module OpenFileDialog
      # Show a modal open-file dialog. Returns the chosen path, or nil
      # on cancel / when no dialog tool is available.
      #
      # * *title*   — dialog window title.
      # * *filters* — glob patterns, e.g. `["*.png", "*.jpg"]`; empty
      #               means all files.
      # * *directory* — where the dialog starts.
      def self.show(title : String = "Open file",
                    filters : Array(String) = [] of String,
                    directory : String? = nil) : String?
        Dialogs.open(title, filters, directory)
      end
    end

    module SaveFileDialog
      # Show a modal save-file dialog. Returns the chosen path, or nil
      # on cancel / when no dialog tool is available.
      def self.show(title : String = "Save file",
                    filters : Array(String) = [] of String,
                    directory : String? = nil,
                    default_name : String? = nil) : String?
        Dialogs.save(title, filters, directory, default_name)
      end
    end

    # zenity/kdialog plumbing shared by the dialog-based system ports.
    module Dialogs
      @@tool : String?

      # First available dialog helper on PATH: "zenity", "kdialog" or nil.
      def self.tool : String?
        @@tool ||= which("zenity") || which("kdialog")
      end

      # First entry on PATH named `name` that is executable, or nil.
      def self.which(name : String) : String?
        ENV["PATH"]?.try &.split(':').each do |dir|
          next if dir.empty?
          path = File.join(dir, name)
          return name if executable?(path)
        end
      end

      EXEC_BITS = File::Permissions::OwnerExecute |
                  File::Permissions::GroupExecute |
                  File::Permissions::OtherExecute

      private def self.executable?(path : String) : Bool
        info = File.info?(path)
        !info.nil? && !(info.not_nil!.permissions & EXEC_BITS).to_i.zero?
      end

      def self.open(title : String, filters : Array(String),
                    directory : String?) : String?
        return nil unless {{ flag?(:unix) }}
        case tool
        when "zenity"
          args = ["--file-selection", "--title=#{title}"]
          args << "--file-filter=Files | #{filters.join(" ")}" unless filters.empty?
          args << "--filename=#{File.join(directory, "/")}" if directory
          run("zenity", args)
        when "kdialog"
          args = ["--getopenfilename", directory || Dir.current]
          args << filters.join(" ") unless filters.empty?
          args.concat(["--title", title])
          run("kdialog", args)
        end
      end

      def self.save(title : String, filters : Array(String),
                    directory : String?, default_name : String?) : String?
        return nil unless {{ flag?(:unix) }}
        case tool
        when "zenity"
          args = ["--file-selection", "--save", "--title=#{title}"]
          args << "--file-filter=Files | #{filters.join(" ")}" unless filters.empty?
          args << "--filename=#{File.join(directory || Dir.current, default_name || "")}"
          run("zenity", args)
        when "kdialog"
          start = File.join(directory || Dir.current, default_name || "")
          args = ["--getsavefilename", start]
          args << filters.join(" ") unless filters.empty?
          args.concat(["--title", title])
          run("kdialog", args)
        end
      end

      # Run the dialog tool; nil unless it exited 0 with a path.
      def self.run(name : String, args : Array(String)) : String?
        output = IO::Memory.new
        status = Process.run(name, args, output: output, error: IO::Memory.new)
        return nil unless status.success?
        result = output.to_s.strip
        result.empty? ? nil : result
      end

      # Run a tool and report only whether it exited 0 (cancel → false).
      def self.run?(name : String, args : Array(String)) : Bool
        Process.run(name, args, output: IO::Memory.new,
          error: IO::Memory.new).success?
      end
    end
  end
end
