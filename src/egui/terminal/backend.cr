# Terminal backend seam: everything the TermView needs from a
# PTY-backed terminal session. `Session` (backend/pty.cr) is the
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
