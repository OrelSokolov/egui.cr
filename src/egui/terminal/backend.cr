# Terminal backend seam: everything the TermView needs from a
# PTY-backed terminal session. `Session` (terminal/pty.cr) is the
# native implementation; specs and tests drive it with a fake.

module Egui
  module Terminal
    abstract class Backend
      # The emulator state to render.
      abstract def term : Terminal

      # Pull newly arrived PTY bytes into the emulator (and flush
      # emulator replies back). Call once per frame; returns true when
      # the visible state changed.
      abstract def pump : Bool

      # One bounded evented scheduler pass per FRAME — under the native
      # backend the sokol loop never yields to the Crystal scheduler,
      # so this is what lets PTY data reach the reader fibers (see
      # Session#evented_pass: a ~1 ms select, deduped by the frame
      # time so every TermView/pump in one frame shares a single
      # pass — the frame cost stays flat as sessions grow). The
      # default is a no-op: fake/headless backends have no reader
      # fibers. Call before #pump.
      def evented_pass(frame_time : Float64) : Nil
      end

      # Send input bytes to the child.
      abstract def write(bytes : Bytes) : Nil

      # Resize the emulator AND the PTY.
      abstract def resize(cols : Int32, rows : Int32) : Nil

      abstract def alive? : Bool
      # Exit code once dead, nil while alive/unknown.
      abstract def exit_code : Int32?
      # Ask the child to die (async; the session reaps itself).
      abstract def close : Nil
    end
  end
end
