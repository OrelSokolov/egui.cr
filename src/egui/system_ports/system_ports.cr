# System ports: the OS/windowing surface an app can call from `update` —
# quit, native file dialogs, and so on. Every port lives in exactly one
# file under `Egui::SystemPorts` (this directory).
#
# Like the rest of the core, ports stay headless-testable: a port either
# shells out through the Crystal stdlib (dialogs, message box, shell,
# notifications, user dirs) or delegates to an installable implementation
# that the backend wires to native calls (quit, window, screen,
# clipboard — see backend/sokol.cr).

require "./quit"
require "./dialog"
require "./message_box"
require "./clipboard"
require "./window"
require "./screen"
require "./shell"
require "./notification"
require "./user_dirs"
require "./fonts"
