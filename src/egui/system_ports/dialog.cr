# System ports OpenFileDialog / SaveFileDialog: native file pickers.
#
# Linux/BSD shell out to `zenity` (GNOME &c) or `kdialog` (KDE), the
# common toolkit-free way to get a native dialog — no extra windowing
# dependency. Other platforms are not wired yet: the request completes
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

      # The blocking dialog runners are protected: the only public path
      # is the fiber-backed `OpenFileDialog.show` / `SaveFileDialog.show`
      # — a dialog must never block the caller's fiber.

      protected def self.open(title : String, filters : Array(String),
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

      protected def self.save(title : String, filters : Array(String),
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
