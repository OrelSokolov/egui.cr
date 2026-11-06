# Driver entry point for apps: compiles the default (sokol) driver in
# and exposes the driver-agnostic `Egui.run` facade (upstream eframe's
# role). Apps require THIS file instead of a concrete driver, so a
# future second driver (WebView, …) swaps here — once — and no app
# changes.
#
# Vocabulary (plans/frontend-backend-split.md §2): the former
# `backend/` is the DRIVER — window, frame loop, GPU, input. The word
# "backend" now belongs to the application-logic layer (`egui/mvc/`).
#
# The headless core (`require "egui"`) stays driver-free: specs and
# library consumers never pull native code through this file.

require "./driver/sokol"

module Egui
  # Run an app under the compiled-in driver. All options forward to
  # the driver (`Driver::Sokol.run` stays public for sokol-specific
  # knobs — chrome styles, detached-mode env).
  def self.run(app : App, **opts) : Nil
    Driver::Sokol.run(app, **opts)
  end
end
