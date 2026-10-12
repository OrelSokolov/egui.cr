# Android system-ports bridge (ANDROID_SUPPORT_PLAN.md, phase 7): the JNI
# surface behind the ports when the app runs as an Android NativeActivity.
#
# Crystal (sokol's loop thread) calls the egui_cr_android_* functions in
# backend/sokol_shim.c, which invoke static helpers on
# com.eguicr.ime.EguiCrActivity. Results the OS delivers asynchronously on
# the Java UI thread (SAF picker via onActivityResult, MessageBox confirm
# buttons, clipboard changes) land in a mutex ring that #pump — wired into
# Sokol#on_frame next to the IME drain — translates back into port
# completions between frames.
#
# Headless/desktop builds compile the constants only: every port file
# reaches this module behind `flag?(:android)` branches.

module Egui
  module SystemPorts
    module Android
      # SAF picker kinds (Intent actions, mirrored in the shim).
      SAF_OPEN  = 1
      SAF_SAVE  = 2
      SAF_TREE  = 3

      # sysDir ids: 0 files / 1 cache / 2 home / 3 documents /
      # 4 downloads / 5 pictures / 6 music / 7 videos.
      DIR_FILES      = 0
      DIR_CACHE      = 1
      DIR_HOME       = 2
      DIR_DOCUMENTS  = 3
      DIR_DOWNLOADS  = 4
      DIR_PICTURES   = 5
      DIR_MUSIC      = 6
      DIR_VIDEOS     = 7

      {% if flag?(:android) %}
        lib LibAndroidSys
          struct SysRec
            type : Int32
            seq : Int32
            value : Int32
            path : UInt8[1040]
          end

          fun notify = egui_cr_android_notify(title : UInt8*, body : UInt8*) : Void
          fun open_url = egui_cr_android_open_url(url : UInt8*) : Int32
          fun msgbox = egui_cr_android_msgbox(level : Int32, title : UInt8*, msg : UInt8*, confirm : Int32) : Void
          fun clipboard_set = egui_cr_android_clipboard_set(text : UInt8*) : Void
          fun clipboard_get = egui_cr_android_clipboard_get : UInt8*
          fun saf_start = egui_cr_android_saf_start(seq : Int32, kind : Int32, title : UInt8*, mime : UInt8*, default_name : UInt8*) : Int32
          fun sys_pop = egui_cr_android_sys_pop(out : SysRec*, cap : Int32) : Int32
          fun dir = egui_cr_android_dir(which : Int32, out : UInt8*, cap : Int32) : Int32
          fun read_uri_text = egui_cr_android_read_uri_text(uri : UInt8*) : UInt8*
          fun mem_free = egui_cr_mem_free(p : Void*) : Void
        end

        @@saf_seq = 0
        @@saf = {} of Int32 => AsyncDialogs::Request
        @@confirm_cb : (Bool ->)?

        # Notification port: fire-and-forget. On API 33+ the first call
        # triggers the POST_NOTIFICATIONS request from the activity; until
        # the user grants it the system drops the notification silently —
        # never an error for the app.
        def self.notify(title : String, body : String) : Nil
          LibAndroidSys.notify(title.to_unsafe, body.to_unsafe)
        end

        # Shell port OpenUrl: ACTION_VIEW with the default handler.
        def self.open_url(url : String) : Bool
          LibAndroidSys.open_url(url.to_unsafe) != 0
        end

        # MessageBox level ids (EguiCrActivity.showMessageBox).
        MSG_INFO    = 0
        MSG_WARNING = 1
        MSG_ERROR   = 2
        MSG_QUESTION = 3

        def self.msgbox(level : Int32, title : String, message : String) : Nil
          LibAndroidSys.msgbox(level, title.to_unsafe, message.to_unsafe, 0)
        end

        # Yes/no box; the answer arrives in #pump on a later frame.
        def self.confirm_async(title : String, message : String,
                               &on_result : Bool ->) : Nil
          @@confirm_cb = on_result
          LibAndroidSys.msgbox(MSG_QUESTION, title.to_unsafe,
                               message.to_unsafe, 1)
        end

        # Yes/no box without a callback — the sync-confirm fallback on
        # Android, where the answer cannot return synchronously (the
        # dialog runs on the OS UI thread; blocking the frame loop would
        # stall input dispatch → ANR).
        def self.confirm_box(title : String, message : String) : Nil
          LibAndroidSys.msgbox(MSG_QUESTION, title.to_unsafe,
                               message.to_unsafe, 1)
        end

        # Clipboard: set writes through ClipboardManager and warms the
        # native cache; get reads the cache kept current by the Java-side
        # OnPrimaryClipChangedListener (the UI thread is the only one
        # allowed to read the system clipboard).
        def self.clipboard_set(text : String) : Nil
          text.to_unsafe # ensure a contiguous buffer
          LibAndroidSys.clipboard_set(text.to_unsafe)
        end

        def self.clipboard_get : String?
          ptr = LibAndroidSys.clipboard_get
          return nil if ptr.null?
          begin
            String.new(ptr)
          ensure
            LibAndroidSys.mem_free(ptr.as(Void*))
          end
        end

        # UserDirs: one JNI roundtrip per dir, cached by the caller.
        def self.dir(which : Int32) : String?
          buf = StaticArray(UInt8, 512).new(0)
          return nil if LibAndroidSys.dir(which, buf.to_unsafe, 512) == 0
          String.new(buf.to_unsafe)
        end

        # Up to ~64 KB of a content:// document as text; nil when the
        # content resolver refuses. The SAF pickers return URIs, not
        # paths — this is how app code reads what was picked.
        def self.read_uri_text(uri : String) : String?
          ptr = LibAndroidSys.read_uri_text(uri.to_unsafe)
          return nil if ptr.null?
          begin
            String.new(ptr)
          ensure
            LibAndroidSys.mem_free(ptr.as(Void*))
          end
        end

        # Start a SAF picker for a detached dialog request; the result
        # completes in #pump. `mime` is a single MIME type (see
        # .mime_for); `default_name` pre-fills the save dialog.
        def self.saf_open(kind : Int32, title : String, mime : String,
                          default_name : String?,
                          req : AsyncDialogs::Request) : Nil
          seq = (@@saf_seq += 1)
          @@saf[seq] = req
          name = default_name || ""
          if LibAndroidSys.saf_start(seq, kind, title.to_unsafe,
                                     mime.to_unsafe, name.to_unsafe) == 0
            @@saf.delete(seq)
            AsyncDialogs.complete(req, nil)
          end
        end

        # Common filename extension → MIME type (SAF filters by MIME, not
        # glob); unknown or mixed filters fall back to */*.
        MIME = {"png" => "image/png", "jpg" => "image/jpeg",
                "jpeg" => "image/jpeg", "gif" => "image/gif",
                "bmp" => "image/bmp", "webp" => "image/webp",
                "svg" => "image/svg+xml", "txt" => "text/plain",
                "md" => "text/plain", "json" => "application/json",
                "csv" => "text/csv", "pdf" => "application/pdf",
                "mp3" => "audio/mpeg", "ogg" => "audio/ogg",
                "wav" => "audio/x-wav", "mp4" => "video/mp4",
                "webm" => "video/webm", "zip" => "application/zip"}

        def self.mime_for(filters : Array(String)) : String
          mimes = filters.map do |f|
            MIME[f[2..].downcase]? if f.starts_with?("*.")
          end.compact.uniq
          mimes.size == 1 ? mimes.first : "*/*"
        end

        # Drain result records (SAF picks, confirm answers) queued by the
        # Java UI thread. Called from Sokol#on_frame BEFORE the idle check
        # so a completion always forces a full frame; the callbacks run
        # between frames, like the async-dialog fiber deliveries.
        def self.pump : Nil
          recs = Pointer(LibAndroidSys::SysRec).malloc(16)
          while (n = LibAndroidSys.sys_pop(recs, 16)) > 0
            n.times do |i|
              r = recs[i]
              case r.type
              when 1 # SAF result
                if (req = @@saf.delete(r.seq))
                  AsyncDialogs.complete(req,
                    r.value == 1 ? String.new(r.path.to_unsafe) : nil)
                end
              when 2 # MessageBox confirm
                if (cb = @@confirm_cb)
                  @@confirm_cb = nil
                  AsyncDialogs.note_delivered
                  cb.call(r.value == 1)
                end
              end
            end
          end
        end
      {% end %}
    end
  end
end
