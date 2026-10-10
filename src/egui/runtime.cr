# Backend/runtime hooks the CORE needs but must not depend on.
#
# The core (everything outside `backend/`) is headless-testable and never
# requires the sokol backend file — so the handful of runtime facts the
# core would like to know live here, in plain class-level state the
# backend sets at startup:
#
#   `natural_scheduler?` — true when the app loop owns the Crystal
#     scheduler (the detached render-loop backend): reader fibers run on
#     their own, so the per-frame scheduler crutches
#     (`Runtime.frame_scheduler_pass`, `AsyncDialogs.pump`) are
#     unnecessary and are skipped.
#   `wake` — the backend's "produce a frame" doorbell, called by
#     `Context#request_repaint` from fibers that run BETWEEN frames
#     (PTY readers, async dialogs). Inside a frame it is skipped: the
#     driving frame already bought the settle repaints and the loop
#     re-checks `needs_repaint?` after every frame it produces.
#   `frame_scheduler_pass` — optional per-frame scheduler pass the
#     backend frame loop calls before begin_frame (the same slot
#     `AsyncDialogs.pump_pass` fills for dialogs). Native subsystems
#     whose reader fibers only run when something yields (PTY sessions
#     under the legacy single-thread loop) install it at require time;
#     UI widgets never participate in scheduler management.
module Egui
  module Runtime
    class_property? natural_scheduler : Bool = false
    class_property wake : Proc(Nil)? = nil
    class_property frame_scheduler_pass : Proc(Nil)? = nil
  end
end
