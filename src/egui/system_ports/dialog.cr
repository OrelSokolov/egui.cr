# System ports OpenFileDialog / SaveFileDialog: native file pickers.
#
# Linux/BSD shell out to `zenity` (GNOME &c) or `kdialog` (KDE), the
# common toolkit-free way to get a native dialog; macOS shells out to
# `osascript` (AppleScript `choose file` / `choose file name`). Windows
# runs the WinForms picker through PowerShell (`System.Windows.Forms` —
# part of the OS, no extra dependency); the script travels base64-
# encoded (`-EncodedCommand`) so titles, filters and paths need no
# quoting gymnastics. Other platforms are not wired yet: the request
# completes with nil on the next frame.
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

    module PickFolderDialog
      # Start a non-blocking pick-a-DIRECTORY dialog. Returns
      # immediately; `on_done` receives the chosen folder path, or nil
      # on cancel / when no dialog tool is available, on a later frame.
      # Same async contract as OpenFileDialog.show.
      #
      # * *title*     — dialog window title.
      # * *directory* — where the dialog starts.
      def self.show(title : String = "Choose folder",
                    directory : String? = nil,
                    &on_done : String? ->) : Nil
        AsyncDialogs.start(->{ Dialogs.pick_folder(title, directory) }, on_done)
      end
    end

    # Fiber-backed request registry behind the async dialogs.
    #
    # Delivery model: the worker fiber calls `on_done` itself the moment
    # `work` finishes (same thread, always BETWEEN frames — the backend
    # loop may be blocked in its scheduler wait, never mid-frame) and
    # bumps a delivered counter that the backend consumes as a
    # produce-a-frame trigger (`take_delivered`). With the detached
    # backend the scheduler runs fibers naturally, so completion also
    # knocks on the backend doorbell via `Egui::Runtime.wake`; with the
    # legacy single-thread backend (`sapp_run` never yields), the
    # backend gives the scheduler one bounded pass per frame
    # (`pump_pass`) — completions land during that pass and are counted
    # the same way.
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
      @@delivered = 0

      # Start `work` in its own fiber; `on_done` fires when `work`
      # finishes (in that fiber — see the module comment).
      def self.start(work : -> String?, on_done : String? ->) : Request
        req = Request.new(on_done)
        @@pending << req
        spawn do
          req.result = work.call
          req.done = true
          @@pending.delete(req)
          @@delivered += 1
          req.complete
          Egui::Runtime.wake.try &.call
        end
        req
      end

      # True while at least one dialog is open — for spinners etc.
      def self.pending? : Bool
        !@@pending.empty?
      end

      # Legacy backend crutch: one bounded scheduler pass per frame so
      # worker fibers advance inside sapp_run's blocking C loop. The
      # detached backend never calls this — its fibers run between
      # frames on their own.
      def self.pump_pass : Nil
        unless @@pending.empty?
          select
          when timeout(1.milliseconds)
          end
        end
      end

      # Consume the completed-request count — their callbacks already
      # ran; the count only tells the backend a full frame must follow.
      def self.take_delivered : Int32
        n = @@delivered
        @@delivered = 0
        n
      end
    end

    # Dialog-tool plumbing shared by the dialog-based system ports:
    # zenity/kdialog on Linux/BSD, osascript (AppleScript) on macOS;
    # on Windows this module also hosts the PowerShell runner used by
    # the notification port and the headless (no-backend) fallback of
    # the file dialogs.
    module Dialogs
      @@tool : String?

      # Native file-dialog runner installed by the backend when it has
      # a platform picker (Win32 IFileDialog via the sokol shim thread
      # — instant, Explorer-native, no PowerShell/.NET startup cost).
      # Called inside the AsyncDialogs worker fiber: it may block that
      # fiber alone. Installed only on win32; nil = headless build →
      # the PowerShell fallback takes over.
      @@native : ((Bool, String, Array(String), String?, String?) -> String?)?

      def self.use_native_dialogs(&runner : Bool, String, Array(String),
                                  String?, String? -> String?) : Nil
        @@native = runner
      end

      # Drop an installed native runner — the subprocess fallback takes
      # over again. Spec hygiene; apps rarely need this.
      def self.use_native_dialogs : Nil
        @@native = nil
      end

      # First available dialog helper on PATH: "osascript" on macOS,
      # "zenity" or "kdialog" on Linux/BSD, or nil. Windows never needs
      # one — the ports go through PowerShell/Win32.
      def self.tool : String?
        {% if flag?(:win32) %}
          nil
        {% else %}
          @@tool ||=
            if {{ flag?(:darwin) }}
              which("osascript")
            else
              which("zenity") || which("kdialog")
            end
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
          if (runner = @@native)
            runner.call(false, title, filters, directory, nil)
          else
            ps_dialog("OpenFileDialog", title, filters, directory, nil)
          end
        {% elsif flag?(:darwin) %}
          mac_choose_file(title, filters, directory)
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
          if (runner = @@native)
            runner.call(true, title, filters, directory, default_name)
          else
            ps_dialog("SaveFileDialog", title, filters, directory, default_name)
          end
        {% elsif flag?(:darwin) %}
          mac_choose_file_name(title, directory, default_name)
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

      # Pick a directory (zenity `--directory`, kdialog
      # `--getexistingdirectory`, AppleScript `choose folder`, WinForms
      # FolderBrowserDialog on Windows): nil on cancel.
      protected def self.pick_folder(title : String, directory : String?) : String?
        {% if flag?(:win32) %}
          script = String.build do |s|
            s << "Add-Type -AssemblyName System.Windows.Forms\n"
            s << "$d = New-Object System.Windows.Forms.FolderBrowserDialog\n"
            s << "$d.Description = " << ps_sq(title) << "\n"
            s << "$d.SelectedPath = " << ps_sq(directory) << "\n" if directory
            s << "if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 1 }\n"
            s << "Write-Output $d.SelectedPath\n"
          end
          run_powershell(script)
        {% elsif flag?(:darwin) %}
          script = String.build do |sb|
            sb << "POSIX path of (choose folder with prompt \"#{as_quote(title)}\""
            sb << " default location (POSIX file \"#{as_quote(directory)}\")" if directory
            sb << ")"
          end
          run("osascript", ["-e", script])
        {% else %}
          case tool
          when "zenity"
            args = ["--file-selection", "--directory", "--title=#{title}"]
            args << "--filename=#{File.join(directory, "/")}" if directory
            run("zenity", args)
          when "kdialog"
            args = ["--getexistingdirectory", directory || Dir.current]
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

      # Fire-and-forget process: launch without waiting and report only
      # whether it started. For launchers whose exit code means nothing
      # (explorer) and for work that must not block the frame.
      def self.spawn(name : String, args : Array(String)) : Bool
        Process.new(name, args, output: Process::Redirect::Close,
          error: Process::Redirect::Close)
        true
      rescue
        false
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
          spawn("powershell",
            ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded])
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

      {% if flag?(:darwin) %}
        # --- macOS (osascript / AppleScript) --------------------------------

        # Escape `s` for an AppleScript double-quoted string literal.
        def self.as_quote(s : String) : String
          s.gsub('\\', "\\\\").gsub('"', "\\\"")
        end

        # `choose file` → POSIX path of the pick, or nil on cancel. Only
        # simple `*.ext` filter patterns map to AppleScript `of type`.
        protected def self.mac_choose_file(title : String, filters : Array(String),
                                           directory : String?) : String?
          script = String.build do |sb|
            sb << "POSIX path of (choose file with prompt \"#{as_quote(title)}\""
            exts = filters.map { |f| f.starts_with?("*.") ? f[2..] : nil }.compact
            unless exts.empty?
              sb << " of type {#{exts.map { |e| "\"#{as_quote(e)}\"" }.join(", ")}}"
            end
            sb << " default location (POSIX file \"#{as_quote(directory)}\")" if directory
            sb << ")"
          end
          run("osascript", ["-e", script])
        end

        # `choose file name` (the save dialog) → POSIX path, or nil on
        # cancel.
        protected def self.mac_choose_file_name(title : String, directory : String?,
                                                default_name : String?) : String?
          script = String.build do |sb|
            sb << "POSIX path of (choose file name with prompt \"#{as_quote(title)}\""
            sb << " default name \"#{as_quote(default_name)}\"" if default_name
            sb << " default location (POSIX file \"#{as_quote(directory)}\")" if directory
            sb << ")"
          end
          run("osascript", ["-e", script])
        end

        # `display dialog` — the MessageBox substrate. One OK button, or
        # Cancel+OK when *confirm*: osascript exits 0 only for OK (Cancel
        # raises "User canceled" → nonzero), which `run?` maps to a Bool.
        protected def self.mac_display_dialog(message : String, title : String,
                                              icon : String, confirm : Bool) : Bool
          buttons = confirm ? %({"Cancel", "OK"}) : %({"OK"})
          script = %(display dialog "#{as_quote(message)}" with title "#{as_quote(title)}" ) +
                   %(buttons #{buttons} default button "OK" with icon #{icon})
          run?("osascript", ["-e", script])
        end
      {% end %}
    end
  end
end
