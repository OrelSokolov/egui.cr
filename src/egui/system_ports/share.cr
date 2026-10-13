# System port Share: the platform share sheet. Android raises the
# ACTION_SEND chooser (through the sysport JNI bridge), iOS presents
# UIActivityViewController over sokol's view controller. Desktops have
# no share sheet — the fallback copies the text to the clipboard and
# returns true (the documented "best effort" behavior: the user can
# paste it anywhere).
#
# Fire-and-forget, never blocks.

module Egui
  module SystemPorts
    module Share
      {% if flag?(:android) %}
        lib LibAndroidShare
          fun share = egui_cr_android_share(subject : UInt8*,
                                            text : UInt8*) : Int32
        end

        def self.supported? : Bool
          true
        end

        # `subject` doubles as the share title where the platform shows
        # one (Android chooser subject, iOS leading line).
        def self.text(subject : String, text : String) : Bool
          subject.to_unsafe # ensure contiguous buffers
          text.to_unsafe
          LibAndroidShare.share(subject.to_unsafe, text.to_unsafe) != 0
        end

      {% elsif flag?(:ios) %}
        lib LibIosShare
          fun share = egui_cr_ios_share(subject : UInt8*,
                                        text : UInt8*) : Int32
        end

        def self.supported? : Bool
          true
        end

        def self.text(subject : String, text : String) : Bool
          subject.to_unsafe
          text.to_unsafe
          LibIosShare.share(subject.to_unsafe, text.to_unsafe) != 0
        end

      {% else %}
        def self.supported? : Bool
          false
        end

        # Desktop fallback: clipboard + true (see the file comment).
        def self.text(subject : String, text : String) : Bool
          Clipboard.text = "#{subject}\n\n#{text}"
          true
        end
      {% end %}
    end
  end
end
