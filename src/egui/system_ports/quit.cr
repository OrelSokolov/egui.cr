# System port Quit: cross-platform application exit — closes the window
# and leaves the backend run loop (eframe: the window close button /
# `ControlFlow::Exit`; sokol: `sapp_quit`).
#
# The core stays headless: `Quit.quit!` delegates to an installable
# implementation; the backend (backend/sokol.cr) wires it to the native
# call, specs run against the no-op default.

module Egui
  module SystemPorts
    module Quit
      class_getter implementation : Implementation = Implementation.new

      # Install a platform implementation (called by the backend).
      def self.use(implementation : Implementation) : Nil
        @@implementation = implementation
      end

      # Close the window and exit the application.
      def self.quit! : Nil
        implementation.quit
      end

      # Platform seam; the default is a headless no-op.
      class Implementation
        def quit : Nil
        end
      end
    end
  end
end
