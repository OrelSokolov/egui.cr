# iOS system-ports bridge: the UIKit surface behind the ports when the
# app runs under the sokol iOS backend (SH_IOS in backend/sokol_shim.c).
#
# Crystal's frame thread calls the egui_cr_ios_* functions, which drive
# UIKit straight — the app is single-threaded and sokol's frame callback
# runs on the main run loop, so UIKit delegate callbacks (alert buttons,
# document pickers) land BETWEEN frames. Results the OS delivers
# asynchronously (the MessageBox confirm answer) travel through a
# static that #pump — wired into Sokol#on_frame next to the Android
# ring drain — translates back into port completions between frames.
#
# Headless/desktop builds compile nothing: every port file reaches this
# module behind `flag?(:ios)` branches.

module Egui
  module SystemPorts
    module Ios
      # Document-picker modes (mirrored in the shim).
      PICK_OPEN   = 0
      PICK_SAVE   = 1
      PICK_FOLDER = 2

      {% if flag?(:ios) %}
        lib LibIosSys
          fun clipboard_set = egui_cr_ios_clipboard_set(utf8 : UInt8*) : Int32
          fun clipboard_get = egui_cr_ios_clipboard_get : UInt8*
          fun open_url = egui_cr_ios_open_url(url : UInt8*) : Int32
          fun msgbox = egui_cr_ios_msgbox(title : UInt8*, msg : UInt8*, confirm : Int32) : Void
          fun msgbox_take = egui_cr_ios_msgbox_take : Int32
          fun docpick_start = egui_cr_docpick_start(mode : Int32, comma_exts : UInt8*, default_name : UInt8*) : Int32
          fun docpick_done = egui_cr_docpick_done : Int32
          fun docpick_take = egui_cr_docpick_take : UInt8*
          fun docpick_free = egui_cr_docpick_free(path : UInt8*)
        end

        @@confirm_cb : (Bool ->)?

        # Clipboard: UIPasteboard (sokol_app has no clipboard on iOS).
        def self.clipboard_set(text : String) : Nil
          text.to_unsafe # ensure a contiguous buffer
          LibIosSys.clipboard_set(text.to_unsafe)
        end

        def self.clipboard_get : String?
          ptr = LibIosSys.clipboard_get
          return nil if ptr.null?
          begin
            String.new(ptr)
          ensure
            LibIosSys.docpick_free(ptr)
          end
        end

        # Shell port OpenUrl: UIApplication openURL.
        def self.open_url(url : String) : Bool
          url.to_unsafe
          LibIosSys.open_url(url.to_unsafe) != 0
        end

        # MessageBox: UIAlertController over sokol's view controller.
        # Info/warning/error are fire-and-forget (a single OK button).
        def self.msgbox(title : String, message : String) : Nil
          LibIosSys.msgbox(title.to_unsafe, message.to_unsafe, 0)
        end

        # Yes/no box; the answer arrives in #pump on a later frame.
        def self.confirm_async(title : String, message : String,
                               &on_result : Bool ->) : Nil
          @@confirm_cb = on_result
          LibIosSys.msgbox(title.to_unsafe, message.to_unsafe, 1)
        end

        # Yes/no box without a callback — the sync-confirm fallback on
        # iOS, where the answer cannot return synchronously (the alert
        # runs on the OS UI thread; blocking the frame loop would stall
        # input dispatch).
        def self.confirm_box(title : String, message : String) : Nil
          LibIosSys.msgbox(title.to_unsafe, message.to_unsafe, 1)
        end

        # Blocking document-picker session — BLOCKS THE CALLING FIBER
        # ONLY (sleep-poll; AsyncDialogs runs this in its worker fiber,
        # so the frame loop keeps rendering while the picker is up).
        # `comma_exts` filters the open mode ("png,jpg" or "" for any);
        # `default_name` pre-names the save temp file.
        def self.document_pick(mode : Int32, comma_exts : String,
                               default_name : String? = nil) : String?
          exts = comma_exts.to_unsafe
          name = (default_name || "").to_unsafe
          return nil if LibIosSys.docpick_start(mode, exts, name) != 0
          until LibIosSys.docpick_done != 0
            sleep 20.milliseconds
          end
          ptr = LibIosSys.docpick_take
          return nil if ptr.null?
          begin
            String.new(ptr)
          ensure
            LibIosSys.docpick_free(ptr)
          end
        end

        # Drain the MessageBox confirm answer queued by the UIKit run
        # loop. Called from Sokol#on_frame BEFORE the idle check; the
        # callback runs between frames, like the async-dialog fiber
        # deliveries, and note_delivered forces a full frame for it.
        def self.pump : Nil
          answer = LibIosSys.msgbox_take
          return if answer.zero?
          if (cb = @@confirm_cb)
            @@confirm_cb = nil
            AsyncDialogs.note_delivered
            cb.call(answer == 1)
          end
        end
      {% end %}
    end
  end
end
