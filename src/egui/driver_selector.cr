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

# Startup-crash report (egui/crash_report.cr): a raise before the
# frame loop exists — typically the App constructor, e.g. a missing
# asset when launched from a file manager with a foreign cwd —
# escapes Egui.run before any window opens; the runtime prints it to
# STDERR (invisible for GUI launches) and exits. Catch it here and
# show the engine's crash window with the message + backtrace
# instead. EGUI_NO_CRASH_UI=1 opts out (CI, bisects), spec binaries
# and headless sessions (no DISPLAY/WAYLAND_DISPLAY) keep the plain
# exit — the exception is already on STDERR there.
at_exit do |code, ex|
  next if ex.nil? || ENV["EGUI_NO_CRASH_UI"]? == "1"
  # A live Sokol loop owns the window/GL context — a second run here
  # would crash it; in-loop raises are handled per-frame instead.
  next if Egui::Driver::Sokol.loop_started?
  {% if flag?(:spec) %}
    next
  {% end %}
  {% if flag?(:linux) && !flag?(:android) %}
    next unless ENV["DISPLAY"]? || ENV["WAYLAND_DISPLAY"]?
  {% end %}
  begin
    Egui.run(Egui::CrashReportApp.new(ex),
      title: "egui-cr — crash report",
      width: 680, height: 520)
  rescue
    # The report window itself failed (no GL, torn driver state) —
    # the runtime already printed the exception to STDERR.
  end
end
