# System ports OpenFileDialog / SaveFileDialog: native file pickers.
#
# Linux/BSD shell out to `zenity` (GNOME &c) or `kdialog` (KDE), the
# common toolkit-free way to get a native dialog. Windows runs the
# WinForms picker through PowerShell (`System.Windows.Forms` — part of
# the OS, no extra dependency); the script travels base64-encoded
# (`-EncodedCommand`) so titles, filters and paths need no quoting
# gymnastics. Other platforms are not wired yet: the request completes
# with nil on the next frame.
#
# The call is NEVER blocking: `show` only starts a request and returns
# immediately. The dialog itself runs in its own fiber (`AsyncDialogs`)
# and the blocking `Process.run` suspends that fiber alone — the frame
# loop keeps rendering while the picker is open. The chosen path (or
# nil on cancel) arrives in the `on_done` callback on a later frame,
# dispatched by the backend's `AsyncDialogs.pump` before `app.update`,
# so callbacks always run in the main fiber and may touch app state.

module Egui
  module SystemPorts
    module OpenFileDialog
      # Start a non-blocking open-file dialog. Returns immediately;
      # `on_done` receives the chosen path, or nil on cancel / when no
      # dialog tool is available, on a later frame.
      #
      # * *title*   — dialog window title.
      # * *filters* — glob patterns, e.g. `["*.png", "*.jpg"]`; empty
      #               means all files.
      # * *directory* — where the dialog starts.
      def self.show(title : String = "Open file",
                    filters : Array(String) = [] of String,
                    directory : String? = nil,
                    &on_done : String? ->) : Nil
        AsyncDialogs.start(->{ Dialogs.open(title, filters, directory) }, on_done)
      end
    end

    module SaveFileDialog
      # Start a non-blocking save-file dialog. Returns immediately;
      # `on_done` receives the chosen path, or nil on cancel / when no
      # dialog tool is available, on a later frame.
      def self.show(title : String = "Save file",
                    filters : Array(String) = [] of String,
                    directory : String? = nil,
                    default_name : String? = nil,
                    &on_done : String? ->) : Nil
        AsyncDialogs.start(
          ->{ Dialogs.save(title, filters, directory, default_name) }, on_done)
      end
    end

    # Fiber-backed request registry behind the async dialogs. The run
    # loop (`sapp_run`) never returns control to the Crystal scheduler,
    # so the backend pumps it from `on_frame`: one bounded scheduler
    # pass per frame lets worker fibers advance while the UI renders,
    # and completed requests are delivered before `app.update`.
    #
    # Everything lives on one thread (fibers switch cooperatively), so
    # the queues need no locks.
    module AsyncDialogs
      # One in-flight dialog: its worker fiber and delivery callback.
      class Request
        def initialize(@on_done : String? ->)
        end

        property result : String? = nil
        property? done = false

        def complete : Nil
          @on_done.call(@result)
        end
      end

      @@pending = [] of Request
      @@done = [] of Request

      # Start `work` in its own fiber; `on_done` fires on the frame
      # after `work` finishes (see `pump`).
      def self.start(work : -> String?, on_done : String? ->) : Request
        req = Request.new(on_done)
        @@pending << req
        spawn do
          req.result = work.call
          req.done = true
          @@pending.delete(req)
          @@done << req
        end
        req
      end

      # True while at least one dialog is open — for spinners etc.
      def self.pending? : Bool
        !@@pending.empty?
      end

      # Give worker fibers a bounded scheduler pass and deliver every
      # completed request. Called by the backend at frame start; safe
      # to call from specs (headless) too.
      def self.pump : Nil
        unless @@pending.empty?
          select
          when timeout(1.milliseconds)
          end
        end
        drain unless @@done.empty?
      end

      private def self.drain : Nil
        requests = @@done
        @@done = [] of Request
        requests.each &.complete
      end
    end

    # zenity/kdialog plumbing shared by the dialog-based system ports.
    # On Windows this module also hosts the PowerShell runner used by
    # the dialog, message-box and notification ports.
    module Dialogs
      @@tool : String?

      # First available dialog helper on PATH: "zenity", "kdialog" or nil.
      # Windows never needs one — the ports go through PowerShell/Win32.
      def self.tool : String?
        {% if flag?(:win32) %}
          nil
        {% else %}
          @@tool ||= which("zenity") || which("kdialog")
        {% end %}
      end

      # First entry on PATH named `name` that is executable, or nil.
      def self.which(name : String) : String?
        {% if flag?(:win32) %}
          # No execute bits on Windows: existence of name+PATHEXT in a
          # PATH directory is the "executable" test.
          exts = ENV["PATHEXT"]?.try(&.split(';')) || [".exe", ".bat", ".cmd"]
          ENV["PATH"]?.try &.split(';').each do |dir|
            next if dir.empty?
            exts.each do |ext|
              return name if File.file?(File.join(dir, "#{name}#{ext}"))
            end
          end
        {% else %}
          ENV["PATH"]?.try &.split(':').each do |dir|
            next if dir.empty?
            path = File.join(dir, name)
            return name if executable?(path)
          end
        {% end %}
      end

      EXEC_BITS = File::Permissions::OwnerExecute |
                  File::Permissions::GroupExecute |
                  File::Permissions::OtherExecute

      {% unless flag?(:win32) %}
        private def self.executable?(path : String) : Bool
          info = File.info?(path)
          !info.nil? && !(info.not_nil!.permissions & EXEC_BITS).to_i.zero?
        end
      {% end %}

      # The blocking dialog runners are protected: the only public path
      # is the fiber-backed `OpenFileDialog.show` / `SaveFileDialog.show`
      # — a dialog must never block the caller's fiber.

      protected def self.open(title : String, filters : Array(String),
                              directory : String?) : String?
        {% if flag?(:win32) %}
          ps_dialog("OpenFileDialog", title, filters, directory, nil)
        {% else %}
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
        {% end %}
      end

      protected def self.save(title : String, filters : Array(String),
                              directory : String?, default_name : String?) : String?
        {% if flag?(:win32) %}
          ps_dialog("SaveFileDialog", title, filters, directory, default_name)
        {% else %}
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
        {% end %}
      end

      # Run the dialog tool; nil unless it exited 0 with output.
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

      {% if flag?(:win32) %}
        # Run `script` in powershell.exe and return its trimmed stdout;
        # nil on non-zero exit (cancel) or empty output. The script is
        # passed as UTF-16LE base64 (`-EncodedCommand`), immune to
        # quoting in titles/filters/paths; `-STA` because WinForms
        # dialogs require a single-threaded apartment.
        def self.run_powershell(script : String) : String?
          encoded = Base64.strict_encode(script.encode("UTF-16LE"))
          output = IO::Memory.new
          status = Process.run("powershell",
            ["-NoProfile", "-NonInteractive", "-STA", "-EncodedCommand", encoded],
            output: output, error: IO::Memory.new)
          return nil unless status.success?
          result = output.to_s.strip
          result.empty? ? nil : result
        end

        # Fire-and-forget PowerShell: spawn without waiting and report
        # only whether the process launched (notifications must not
        # block the frame while the balloon shows).
        def self.spawn_powershell(script : String) : Bool
          encoded = Base64.strict_encode(script.encode("UTF-16LE"))
          Process.new("powershell",
            ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            output: Process::Redirect::Close, error: Process::Redirect::Close)
          true
        rescue
          false
        end

        # A WinForms open/save picker: nil unless the user confirmed a
        # path (`kind` is the WinForms class name).
        protected def self.ps_dialog(kind : String, title : String,
                                     filters : Array(String),
                                     directory : String?,
                                     default_name : String?) : String?
          script = String.build do |s|
            s << "Add-Type -AssemblyName System.Windows.Forms\n"
            s << "$d = New-Object System.Windows.Forms." << kind << "\n"
            s << "$d.Title = " << ps_sq(title) << "\n"
            s << "$d.Filter = " << ps_sq(ps_filter(filters)) << "\n"
            s << "$d.InitialDirectory = " << ps_sq(directory) << "\n" if directory
            s << "$d.FileName = " << ps_sq(default_name) << "\n" if default_name
            s << "$d.RestoreDirectory = $true\n"
            s << "if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 1 }\n"
            s << "Write-Output $d.FileName\n"
          end
          run_powershell(script)
        end

        # PowerShell single-quoted literal: only ' needs escaping ('').
        protected def self.ps_sq(value : String) : String
          "'#{value.gsub('\'', "''")}'"
        end

        # WinForms filter string from glob patterns; empty means all.
        protected def self.ps_filter(filters : Array(String)) : String
          if filters.empty?
            "All files (*.*)|*.*"
          else
            pats = filters.join(";")
            "Files (#{pats})|#{pats}|All files (*.*)|*.*"
          end
        end
      {% end %}
    end
  end
end
