# CrashReport — the engine's built-in crash window. Apps die in two
# places, both covered here:
#
# * *Startup* — a raise before/inside the first frames (typically the
#   App constructor: a missing asset, a bad path, a rejected file)
#   escapes `Egui.run` before any window exists. The runtime prints it
#   to STDERR and exits — invisible when launched from a file manager
#   or desktop entry, so the binary just "doesn't open". The at_exit
#   hook in driver_selector.cr catches it and boots a standalone
#   report window (CrashReportApp) instead.
# * *Mid-frame* — a raise inside `App#update` is rescued by the
#   driver's frame loop (both loop flavors, see Sokol.run_update):
#   every following frame draws the report instead of the crashed
#   update, and the loop keeps running so the report can be scrolled
#   and copied.
#
# EGUI_NO_CRASH_UI=1 opts out (CI runs, bisects): the process then
# dies with the plain unhandled-exception exit, as before.

module Egui
  module CrashReport
    # The mid-frame capture; nil until an update raised.
    @@captured : Exception? = nil

    def self.captured? : Bool
      !@@captured.nil?
    end

    def self.captured : Exception?
      @@captured
    end

    def self.capture(ex : Exception) : Nil
      @@captured = ex
    end

    # The full text report (class, message, backtrace, cause chain) —
    # one string for the clipboard button.
    def self.report_text(ex : Exception) : String
      String.build do |io|
        format_exception(io, ex)
      end
    end

    def self.format_exception(io : IO, ex : Exception) : Nil
      io << ex.class.name << ": " << ex.message.to_s << '\n'
      if (bt = ex.backtrace?) && !bt.empty?
        io << "  from " << bt.join("\n  from ") << '\n'
      end
      if (cause = ex.cause)
        io << "Caused by:\n"
        format_exception(io, cause)
      end
    end

    # The report UI — a full-window central panel: heading, the
    # exception class, action buttons, then the whole report (message,
    # backtrace, cause chain) in ONE readonly textarea filling the
    # remainder — a real text view you can scroll, select and copy
    # from, not a wall of labels. Drawn in place of the crashed
    # `App#update` (mid-frame) or as the whole app of the standalone
    # report window (startup path).
    def self.draw(ctx : Context, ex : Exception) : Nil
      ctx.central_panel do |ui|
        ui.heading("Application crashed")
        ui.rich(RichText.new(ex.class.name)
          .code
          .color(Color32.rgba(220, 60, 60)))
        ui.horizontal do |h|
          if h.button("Copy report").clicked?
            SystemPorts::Clipboard.text = report_text(ex)
          end
          if h.button("Quit").clicked?
            Process.exit(1)
          end
        end
        ui.separator
        # The textarea fills the panel remainder (Ui#fill_child — the
        # fill-editor pattern; the manual allocate+child_ui idiom sized
        # rows:100 past the fold and never scrolled, see fill_child).
        editor = ui.fill_child(Id.from("crash_report/text"))
        editor.add(TextArea.new(report_text(ex), rows: 100,
          readonly: true))
      end
    end
  end

  # The standalone report window for the startup-crash path: a
  # minimal App whose whole UI is CrashReport.draw — run by the
  # at_exit hook in driver_selector.cr.
  class CrashReportApp < App
    def initialize(@exception : Exception)
      super()
    end

    def update(ctx : Context) : Nil
      CrashReport.draw(ctx, @exception)
    end
  end
end
