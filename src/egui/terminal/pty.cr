# PTY bindings + Session — the native Terminal::Backend.
#
# The shim (backend/pty_shim.c, linked into the egui_cr_sokol native
# library) provides one API over POSIX ptys (Linux/macOS) and ConPTY
# (Windows). Two data paths, both fiber-scheduler-friendly:
#
# The -legui_cr_sokol link flag is declared once, in
# backend/sokol.cr — every terminal app opens a window through the
# sokol backend and requires it alongside this file (repeating
# @[Link] here would duplicate the linker flag and ld warns).
#
#   Unix    — the master fd is wrapped in IO::FileDescriptor (epoll/
#             kqueue): a reader FIBER suspends properly on read, and
#             new data wakes the UI through `on_output` (hook it to
#             ctx.request_repaint). A blocking C read from a fiber
#             would wedge the Crystal scheduler — don't go there.
#             Sokol's frame loop never yields to the scheduler
#             (sapp_run is a blocking C call), so `evented_pass`
#             gives the process ONE bounded pass per frame to deliver
#             pending PTY data to all reader fibers (same trick as
#             AsyncDialogs.pump) — keep the per-frame repaint while a
#             session is alive (TermView does).
#   Windows — the shim's reader thread fills a ring buffer;
#             `pump` drains it per frame (the TermView requests
#             repaints while the session is alive to drive that).
#
# All parser work happens on the frame fiber via the channel, so no
# locking is needed around the emulator.

lib LibPty
  type Pty = Void*

  # argv/env are NULL-terminated UTF-8 arrays; NULL env inherits the
  # parent's. Returns NULL on failure.
  fun spawn = egui_cr_pty_spawn(shell : UInt8*, argv : UInt8**,
                                cwd : UInt8*, env : UInt8**,
                                cols : Int32, rows : Int32) : Pty
  # Blocking read (Unix: only for non-fiber threads; Windows: waits on
  # the ring buffer). -1 = session over.
  fun read = egui_cr_pty_read(pty : Pty, buf : UInt8*, len : Int32) : Int32
  # Non-blocking ring drain: >=0 bytes, 0 = none, -1 = session over.
  fun read_poll = egui_cr_pty_read_poll(pty : Pty, buf : UInt8*, len : Int32) : Int32
  fun write = egui_cr_pty_write(pty : Pty, buf : UInt8*, len : Int32) : Int32
  fun resize = egui_cr_pty_resize(pty : Pty, cols : Int32, rows : Int32)
  # The read end as a plain fd (-1 on ring-buffer platforms). The shim
  # owns the fd until `release_fd` hands the close over to Crystal.
  fun fd = egui_cr_pty_fd(pty : Pty) : Int32
  # The child's pid, -1 = none/failed. Valid until reap frees the
  # session — cache it at spawn, don't call later.
  fun pid = egui_cr_pty_pid(pty : Pty) : Int32
  # Hand the fd's close to Crystal: after this, `IO#close` (not reap)
  # closes it — reap skips the close(2).
  fun release_fd = egui_cr_pty_release_fd(pty : Pty)
  # -2 = still running, else exit code (128+signal when signaled).
  fun wait = egui_cr_pty_wait(pty : Pty, blocking : Int32) : Int32
  fun alive = egui_cr_pty_alive(pty : Pty) : Int32
  # Ask the child to die (async, thread-safe).
  fun close_child = egui_cr_pty_close(pty : Pty)
  # Wait + close + free — call exactly once, after the reader observed
  # EOF (or when abandoning the session).
  fun reap = egui_cr_pty_reap(pty : Pty)
end

module Egui
  module Terminal
    class Session < Backend
      class Error < Exception; end

      getter term : Terminal
      # Child process pid, cached at spawn (the shim frees the session
      # on reap). nil when the platform didn't provide one. Used by
      # hosts for process-tree memory accounting.
      getter pid : Int32?
      property on_output : Proc(Nil)? = nil

      @pty : LibPty::Pty
      @channel = Channel(Bytes).new(128)
      @closed = false
      @dead = false
      @exit_code : Int32? = nil
      @poll_buf = Bytes.new(8192)
      @reaped = false
      @io : IO::FileDescriptor? = nil

      # Frame-time mark of the last evented pass, shared by EVERY
      # session in the process (see #evented_pass).
      @@pass_time : Float64 = -1.0

      # EGUI_FRAME_DEBUG also gates PTY-side logging (reader wakeups,
      # evented-pass cost, session teardown) — see Backend::Sokol.
      def self.debug? : Bool
        ENV["EGUI_FRAME_DEBUG"]? != nil
      end

      def initialize(shell : String? = nil, args : Array(String) = [] of String,
                     cwd : String? = nil, env : Hash(String, String)? = nil,
                     cols : Int32 = 80, rows : Int32 = 24,
                     scrollback : Int32 = 10_000,
                     @on_output : Proc(Nil)? = nil)
        @term = Terminal.new(cols, rows, scrollback)
        shell = self.class.default_shell if shell.nil? || shell.empty?
        argv = [shell] + args
        full_env = (env || ENV.to_h).merge({
          "TERM"      => "xterm-256color",
          "COLORTERM" => "truecolor",
        })

        env_list = full_env.map { |k, v| "#{k}=#{v}" }
        pty = with_c_strings(argv) do |argv_c|
          with_c_strings(env_list) do |env_c|
            cwd_c = cwd ? cwd.to_unsafe : Pointer(UInt8).null
            LibPty.spawn(shell.to_unsafe, argv_c, cwd_c, env_c, cols, rows)
          end
        end
        raise Error.new("pty spawn failed for #{shell}") if pty.null?
        @pty = pty
        pid = LibPty.pid(@pty)
        @pid = pid >= 0 ? pid : nil

        {% unless flag?(:win32) %}
          # Default IO::FileDescriptor is evented (epoll/kqueue) — the
          # reader fiber suspends instead of blocking its worker thread.
          io = IO::FileDescriptor.new(LibPty.fd(@pty))
          # the shim owns the fd until finish hands the close over (see
          # finish) — keep Crystal's finalizer away from it
          io.close_on_finalize = false
          @io = io
          spawn reader_loop, name: "egui-term-reader"
          # The reader must reach its first (evented, suspending) read
          # BEFORE the app enters sokol's blocking C loop — a spawned
          # fiber never starts until the spawning fiber yields, and the
          # main fiber goes straight from here into sapp_run.
          Fiber.yield
        {% end %}
      end

      def self.default_shell : String
        {% if flag?(:win32) %}
          ENV["COMSPEC"]? || "cmd.exe"
        {% else %}
          ENV["SHELL"]? || "/bin/bash"
        {% end %}
      end

      {% unless flag?(:win32) %}
      private def reader_loop : Nil
          io = @io.not_nil!
          buf = Bytes.new(8192)
          loop do
            n = begin
              io.read(buf)
            rescue ex2 : IO::Error
              0 # EIO once the child released the slave = session over
            end
            break if n.zero?
            STDERR.puts "[pty #{@pty.address}] reader: #{n}B" if Session.debug?
            begin
              @channel.send(buf[0, n].dup)
              # Data arrived — wake the UI now (not only at session end)
              # so the next frame pumps the channel into the emulator.
              @on_output.try &.call
            rescue ex3 : Channel::ClosedError
              break
            end
          end
          finish
        rescue ex : IO::Error
          finish
        end
      {% end %}

      # One bounded evented scheduler pass per FRAME, deduped by the
      # frame's input time across every session in the process. Only
      # needed by the LEGACY single-thread backend (sapp_run never
      # yields, so PTY reader fibers would never run); with the detached
      # render loop the scheduler is alive between frames and this is a
      # no-op (Egui::Runtime.natural_scheduler?).
      def evented_pass(frame_time : Float64) : Nil
        {% unless flag?(:win32) %}
          return if Egui::Runtime.natural_scheduler?
          return if frame_time == @@pass_time
          @@pass_time = frame_time
          t0 = Time.instant if Session.debug?
          select
          when timeout(1.millisecond)
          end
          if (d = t0) && (ms = (Time.instant - d).total_milliseconds) > 5.0
            STDERR.puts "[pty] evented_pass took #{"%.1f" % ms}ms (scheduler busy)"
          end
        {% end %}
      end

      # Drain newly arrived bytes into the emulator (and flush emulator
      # replies). Returns true when the visible state changed. The
      # evented pass that fills the channel is #evented_pass — one per
      # frame, shared by all sessions; a drain alone is cheap.
      def pump : Bool
        changed = false
        {% if flag?(:win32) %}
          loop do
            n = LibPty.read_poll(@pty, @poll_buf, @poll_buf.size)
            break if n.zero?
            if n < 0
              finish
              break
            end
            @term.feed(@poll_buf[0, n])
            changed = true
          end
        {% else %}
          chunks = 0
          bytes = 0
          loop do
            select
            when chunk = @channel.receive?
              break if chunk.nil?
              @term.feed(chunk)
              chunks += 1
              bytes += chunk.size
              changed = true
            else
              break
            end
          end
          if changed && Session.debug?
            STDERR.puts "[pty #{@pty.address}] pump: #{chunks} chunks / #{bytes}B"
          end
        {% end %}
        if changed && (outp = @term.drain_output)
          begin
            write(outp)
          rescue Error
          end
        end
        changed
      end

      def write(bytes : Bytes) : Nil
        return if @dead || @closed
        off = 0
        while off < bytes.size
          n = LibPty.write(@pty, bytes + off, bytes.size - off)
          raise Error.new("pty write failed") if n < 0
          off += n
        end
      end

      def resize(cols : Int32, rows : Int32) : Nil
        @term.resize(cols, rows)
        LibPty.resize(@pty, cols, rows) unless @dead
      end

      def alive? : Bool
        !@dead
      end

      def exit_code : Int32?
        @exit_code
      end

      def close : Nil
        return if @closed || @dead
        @closed = true
        LibPty.close_child(@pty)
      end

      private def finish : Nil
        return if @dead
        @channel.close
        @exit_code = LibPty.wait(@pty, 1)
        @dead = true
        STDERR.puts "[pty #{@pty.address}] finish: session over (exit=#{@exit_code})" if Session.debug?
        # Close the master fd HERE, not behind the shim's back: the
        # scheduler's poller indexes fd state by fd NUMBER, so a foreign
        # close(2) leaves a stale arena slot. The next pty reuses the
        # same number; its first evented read then fails to allocate and
        # busy-loops the scheduler (app-wide hang), and reap's close(2)
        # could hit the reused fd of ANOTHER session (kills the neighbor
        # tab). IO#close deregisters from the poller and closes;
        # release_fd tells the shim not to close again. No-op on Windows
        # (no fd, @io is nil).
        LibPty.release_fd(@pty)
        @io.try &.close
        @on_output.try &.call
        reap
      end

      private def reap : Nil
        return if @reaped
        @reaped = true
        LibPty.reap(@pty)
      end

      # Build a NULL-terminated char** from a String list and yield it
      # (the slice keeps the strings alive for the yield's duration).
      private def with_c_strings(list : Array(String))
        ptrs = Pointer(Pointer(UInt8)).malloc(list.size + 1)
        slices = list.map(&.to_slice)
        list.each_with_index do |_, i|
          ptrs[i] = slices[i].to_unsafe
        end
        ptrs[list.size] = Pointer(UInt8).null
        yield ptrs
      end
    end
  end
end
