# Terminal

A cross-platform terminal emulator on egui-cr — the egui_term role
(alacritty's core replaced by a pure-Crystal VT engine, its PTY layer
replaced by a tiny C shim), ready for tab integration
(`examples/terminal.cr` is a working tabbed terminal).

```
backend/pty_shim.c            POSIX ptys (Linux/macOS) + ConPTY (Windows)
src/egui/terminal/
  theme.cr                    SGR color space (16/256/RGB) + palette
  cell.cr                     grid cell, attribute flags, char width
  grid.cr                     lines + scrollback deque, scroll regions
  parser.cr                   VT500 state machine (Paul Williams design)
  term.cr                     cursor/modes/SGR/selection/replies
  keymap.cr                   keys → xterm byte sequences
  backend.cr                  Backend seam (specs drive it with a fake)
  widget.cr                   TermView: paint + input → ui.terminal
  pty.cr                      LibPty bindings + Session (native backend)
  config.cr                   user profiles: JSON + per-platform store
spec/terminal_spec.cr         VT engine specs (headless)
spec/terminal_widget_spec.cr  widget paint/input specs (headless frames)
spec/terminal_config_spec.cr  profile/store specs (temp dirs)
examples/terminal.cr          tabbed terminal app
```

The core (`theme`…`keymap` + `widget`) is platform-pure and required
from `src/egui.cr`; `pty.cr` links against the native library, so apps
require it explicitly: `require "egui/terminal/pty"`.

## PTY, per platform

|            | mechanism                                    | data path                                     |
|------------|----------------------------------------------|-----------------------------------------------|
| Linux      | `posix_openpt`/`grantpt`/`unlockpt` + `fork`/`setsid` (`TIOCSCTTY`) | master fd wrapped in `IO::FileDescriptor` — epoll-suspending reader fiber |
| macOS      | same                                         | same, via kqueue                              |
| Windows    | ConPTY (`CreatePseudoConsole`, Win10 1809+; resolved dynamically) | shim reader thread → ring buffer → `pump` drains per frame |

The fiber-scheduler constraint drives the design: a Crystal fiber
blocked inside a C `read()` wedges the scheduler's `sleep` (verified on
Crystal 1.21/Linux — the event loop busy-spins and timers never fire).
So on Unix the master fd goes through Crystal's own evented IO, and on
Windows nothing blocks a fiber at all — `Session#pump` (called by the
widget each frame) drains the channel / a non-blocking ring, and
`TermView` requests repaints while its session is alive to keep frames
coming. On Unix the scheduler pass that wakes the reader fibers is
`Session#evented_pass(frame_time)`: ONE ~1 ms pass per frame, deduped
by the frame's input time and shared by every session in the process,
so the frame cost stays flat as tabs grow.

Lifecycle is two-phase because a blocked/blocking read must never touch
freed state: `close` asks the child to die (SIGHUP / ClosePseudoConsole
— safe from any thread), `reap` waits, closes and frees (called once
from the reader path after EOF).

The shim compiles into `libegui_cr_sokol.a` / `egui_cr_sokol.lib` by
`rake build:native` — no new libraries, no new link flags on any of
the three platforms.

## Emulator scope

What a shell, htop and vim need:

- CSI: cursor movement (CUU…HPA), CUP, ED/EL (background-color-erase),
  IL/DL/DCH/ECH/ICH, SU/SD, REP, DECSTBM scroll regions, TBC/HTS tabs
- SGR: attributes (bold/dim/italic/underline/blink/reverse/invisible/
  strike), 16/256/RGB fg+bg, BCE
- DEC modes: 1 (app cursor keys), 6 (origin), 7 (wrap), 25 (cursor),
  47/1047/1048/1049 (alt screen + cursor save), 1000/1002/1003 (mouse),
  1006 (SGR mouse), 2004 (bracketed paste)
- ESC: DECSC/DECRC, IND/RI/NEL/HTS, RIS, DECALN, charsets (G0/G1 + DEC
  line drawing), SS2/SS3 (consumed)
- OSC: 0/1/2 (window/tab title — the tabs example shows it)
- replies: DSR 5/6, primary DA (VT102), window size (CSI 18 t)
- UTF-8 (incremental decode), wide CJK/emoji cells, combining marks
- DCS/SOS/PM/APC payloads are consumed and discarded (no sixel)

Input: full xterm key encoding (Ctrl+letter → C0, Alt → ESC prefix,
modified arrows/F-keys with the `1;m` parameter, SS3 in application
mode), wheel → scrollback on the primary screen / arrow keys on the
alternate screen, scrollback scrollbar (thumb drag, track click =
page) on the right edge while history exists, scrollback paging on
Shift+PageUp/Down and Ctrl+Shift+PageUp/Down, Shift+Home/End jump to
the oldest / live line, SGR + legacy X10 mouse reporting, selection
with copy/paste (Ctrl+Shift+C/V, bracketed paste when the child asks).

Known v1 limitations: no reflow on resize (xterm default), selection
only on the primary screen, OSC 52 (clipboard) and hyperlinks ignored,
no mouse motion reporting in "any" mode without a held button.

## Using it

```crystal
require "egui"
require "egui/terminal/pty"

session = Egui::Terminal::Session.new(
  shell: ENV["SHELL"]?, cwd: Dir.current,
  on_output: ->{ ctx.request_repaint })

ctx.central_panel do |ui|
  ui.terminal(session)          # TermView; computes cols/rows itself
end
```

`Session` API: `term` (the emulator state — title, colors, mouse
modes for the app's own chrome), `pump` (normally called by the
widget), `evented_pass(frame_time)` (the once-per-frame scheduler
pass; the widget triggers it, apps pumping hidden sessions call it
once first), `write`, `resize`, `alive?`, `exit_code`, `close`.

The widget needs a monospace font to align cells; the example picks a
per-platform one via `FreetypeFonts.from_system` and
`Sokol.select_fonts`. With a proportional fallback the terminal still
works, but columns drift.

## Config (user profiles)

`Terminal::Config` persists named user profiles as JSON — window
opacity, background color and the cursor-blink switch:

```json
{
  "active": "default",
  "profiles": {
    "default": {
      "opacity": 0.9,
      "background": "#16161e",
      "cursor_blinks": true
    }
  }
}
```

WHERE the file lives is the framework's config port,
`SystemPorts::AppConfig` (see `system_ports/app_config.cr`), namespaced
as `egui-terminal` — the same platform mapping every app shares
(`Terminal::ConfigStore` is the terminal-module face of it):

|            | path                                                  |
|------------|-------------------------------------------------------|
| Linux/BSD  | `$XDG_CONFIG_HOME/egui-terminal/settings.json` (default `~/.config/…`) |
| macOS      | `~/Library/Application Support/egui-terminal/settings.json` |
| Windows    | `%APPDATA%\egui-terminal\settings.json` (roaming)    |

`SystemPorts::AppConfig.use(dir)` redirects the base directory — the
specs inject a temp dir. `Config.load` defaults on a missing or corrupt
file (a bad settings file never keeps the terminal from booting);
`Config#save` is best effort. `active_profile` falls back to any
surviving profile when the saved name is stale.

Opacity is per-pixel and TERMINAL-ONLY (alacritty's
`background_opacity`, the gnome-terminal behavior): the window runs in
`Sokol.run`'s transparent mode, and the terminal background is written
by `Painter#rect_replace` — a blend-off quad that overwrites the
framebuffer alpha — so the desktop shows through the grid only; the
menu, settings and status panels keep their own opaque fills. Explicit
cell backgrounds follow the theme background's alpha so vim color
schemes turn translucent with the grid instead of punching opaque
holes.

The hard-won part: sokol_gl's `sgl_make_pipeline` defaults its color
write mask to **RGB-only** (`sokol_gl.h`, `_sgl_init_pipeline`) —
alpha writes are masked off, so every sgl quad left the framebuffer
alpha at the clear value (0 in transparent mode) and the compositor
ghosted the whole window. All the shim's pipelines (text, alpha,
replace) now pass `SG_COLORMASK_RGBA` explicitly; verified end-to-end
on XWayland/mutter by reading the window's pixels back (XGetImage):
panels A=255, terminal A=round(opacity·255). Whole-window opacity
remains available separately, at runtime, through
`SystemPorts::Window#set_opacity`.

## Hotkeys caveat

Terminal apps own the keyboard: Ctrl+C, Ctrl+D… are terminal input,
not app shortcuts. Global hotkeys (via `ctx.hotkeys`) dispatch in
`begin_frame` and consume the key before the widget sees it, so bound
combos never reach the child — bind app-wide hotkeys only to combos
the terminal does not want. The example binds Ctrl+T (new tab) and
Ctrl+W (close tab), like gnome-terminal.
