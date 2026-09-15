# System port Clipboard: cross-platform clipboard text, the substrate
# for Ctrl+C/V (TextEdit, components.md phase P7).
#
# Native through sokol_app (`sapp_set/get_clipboard_string`, enabled in
# the shim's sapp_desc). Get reads the system clipboard synchronously on
# desktop backends. The default implementation is an in-memory string so
# specs round-trip headless; the backend installs the real one.

module Egui
  module SystemPorts
    module Clipboard
      class_getter implementation : Implementation = Implementation.new

      # Install a platform implementation (called by the backend).
      def self.use(implementation : Implementation) : Nil
        @@implementation = implementation
      end

      # Current clipboard text, or nil when empty/unavailable.
      def self.text : String?
        implementation.get
      end

      def self.text=(text : String) : String
        implementation.set(text)
        text
      end

      # Platform seam; the default keeps the text in memory (headless).
      class Implementation
        @text = ""

        def set(text : String) : Nil
          @text = text
        end

        def get : String?
          @text
        end
      end
    end
  end
end
