# Backend entry point for apps: compiles the default (sokol) backend in
# and exposes the backend-agnostic `Egui.run` facade (upstream eframe's
# role). Apps require THIS file instead of a concrete backend, so a
# future second backend swaps here — once — and no app changes.
#
# The headless core (`require "egui"`) stays backend-free: specs and
# library consumers never pull native code through this file.

require "./backend/sokol"

module Egui
  # Run an app under the compiled-in backend. All options forward to
  # the backend (`Backend::Sokol.run` stays public for sokol-specific
  # knobs — chrome styles, detached-mode env).
  def self.run(app : App, **opts) : Nil
    Backend::Sokol.run(app, **opts)
  end
end
