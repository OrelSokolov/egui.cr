# System port Events: asynchronous SYSTEM events that arrive outside
# the input pipeline — screen rotation today, theme / battery / app
# lifecycle later. Not a listener thread: the framework owns a
# mutex-guarded queue, and platform code pushes into it from whatever
# thread the OS delivers on (the Android Java UI thread through the
# SysRec ring → Android.pump, the UIKit main run loop through Ios.pump,
# the sokol driver synthesizing from RESIZED on desktop). Apps drain at
# the frame boundary — the same two-sided contract as SDL
# (PushEvent/PollEvent) and the Tray click queue.
#
# Each event kind is its own record; `Event` is the union — extend it
# by adding records, never nullable payload fields. Orientation itself
# is STATE (SystemPorts::Screen.orientation) — the event only signals
# "it changed", carrying the new value for convenience.
#
# Frame contract: `enqueue` marks the queue non-idle (Sokol#on_frame's
# idle gate checks `pending?`), so an event arriving between frames
# forces a full frame in which the app can drain it from `update`.

module Egui
  module SystemPorts
    module Events
      # Every system event kind. New kinds: a record + one more member.
      alias Event = RotationChanged | FullscreenChanged

      # The window/device orientation changed (device rotation, a
      # foldable unfolding, the desktop window crossing the square
      # aspect). `orientation` is the NEW value — also readable as
      # state via SystemPorts::Screen.orientation.
      record RotationChanged, orientation : Egui::Orientation

      # The window mode changed — fullscreen ↔ windowed (a video
      # player's button/hotkey, Esc out of native fullscreen, a WM
      # shortcut). `fullscreen` is the NEW value — also readable as
      # state via SystemPorts::Window.fullscreen?. The backend raises
      # it when its per-frame poll of the live mode first differs from
      # the recorded one, whatever the trigger was.
      record FullscreenChanged, fullscreen : Bool

      # Producer side — ANY thread. Native bridges (Android.pump,
      # Ios.pump, the sokol driver) report here; the optional handler
      # fires on the producer's thread after the event is queued (the
      # handler itself may drain — the lock is not held, like Tray).
      def self.enqueue(event : Event) : Nil
        handler = @@lock.synchronize do
          @@pending << event
          @@handler
        end
        handler.try(&.call(event))
      end

      # Consumer side — drain and clear from `update` (frame boundary).
      def self.take : Array(Event)
        @@lock.synchronize do
          events = @@pending
          @@pending = [] of Event
          events
        end
      end

      # True when undrained events exist — the Sokol idle gate polls
      # this to force a full frame so the app gets to drain them.
      def self.pending? : Bool
        @@lock.synchronize { !@@pending.empty? }
      end

      # Push style — fires as the event arrives, on the producer's
      # thread. Secondary to `take` for immediate-mode apps (same
      # split as Tray.on_click / take_clicks).
      def self.on_event(&block : Event ->) : Nil
        @@handler = block
      end

      @@pending = [] of Event
      @@handler : Proc(Event, Nil)?
      @@lock = Thread::Mutex.new
    end
  end
end
