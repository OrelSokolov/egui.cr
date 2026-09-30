# egui.cr vs other native GUI frameworks

A comparison of egui.cr with native (non-web) GUI frameworks in Rust and
Go, plus Qt/QML as the incumbent. Web wrappers (Electron, Tauri, Wails,
Sciter) are deliberately excluded — that is a different class of tools.

Legend: ✅ — out of the box, ⚠️ — partial / experimental / with caveats,
❌ — no.

| | **egui.cr** (Crystal) | **egui** (Rust) | **iced** (Rust) | **Slint** (Rust) | **Fyne** (Go) | **Gio** (Go) | **Qt/QML** (C++) |
|---|---|---|---|---|---|---|---|
| **Paradigm** | immediate mode + signals | immediate mode | retained, Elm architecture | retained, declarative DSL | retained, canvas | immediate mode | retained (Widgets / QML) |
| **GPU rendering** | ✅ sokol_gfx | ✅ wgpu / glow | ✅ wgpu | ✅ (skia / femtovg / CPU) | ✅ OpenGL | ✅ (Metal/Vulkan/D3D directly) | ✅ RHI (native APIs) |
| **C/C++-free UI stack (widgets, fonts, SVG)** | ✅ everything between the backend and your app is pure Crystal | ✅ pure Rust | ✅ pure Rust | ⚠️ Rust core, host apps often C++ | ⚠️ cgo (OpenGL) | ✅ pure Go, no cgo | ❌ it *is* C++ |
| **Linux / Windows / macOS** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Android / iOS** | ❌ | ⚠️ experimental | ⚠️ experimental | ✅ | ✅ | ✅ | ✅ |
| **Embedded / MCU** | ❌ | ⚠️ (embedded-graphics) | ⚠️ | ✅ MCU profile | ⚠️ | ❌ | ✅ |
| **Reactive state (signals, bindings)** | ✅ `reactive` / `computed`, widgets take the signal itself | ❌ state managed manually by the app | ⚠️ Elm model: message/update, no signals | ✅ property bindings in the DSL, two-way | ✅ `data/binding` | ❌ state managed manually | ✅ property bindings + signals/slots |
| **CSS-like styling** | ✅ full cascade: classes `sidebar.tab`, states `:hover`, `:selected` | ⚠️ `Style` structs, programmatic | ⚠️ theme API, programmatic | ⚠️ styles in the DSL, not CSS | ⚠️ theme API | ⚠️ programmatic (material) | ⚠️ QSS for Widgets, QML has its own |
| **Hot reload / live preview** | ⚠️ fast incremental builds (~1.8 s dev, ~2.1 s `-O3`), no hot swapping | ⚠️ fast `cargo check`, dylib tricks | ❌ | ✅ live-preview from the IDE | ❌ | ❌ | ⚠️ QML reloads at runtime, C++ does not |
| **Widget set out of the box** | ✅ gallery + `NumberInput`, menus, panels, tabs | ✅ rich | ✅ rich | ✅ standard gallery | ✅ | ⚠️ smaller, material set | ✅ the richest |
| **Routing (pages, modals, deep links)** | ✅ `window/page#widget`, `--page root/settings#search` | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ StackView etc., no addressing/deep links |
| **Terminal widget** | ✅ VT500 + PTY/ConPTY, `ui.terminal(session)` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ (third-party only) |
| **SVG** | ✅ own nanosvg port (gradients, dashes, transforms) | ⚠️ via `egui_extras` (usvg) | ✅ `svg` widget | ⚠️ limited | ✅ | ❌ (external packages) | ✅ Qt SVG module |
| **Accessibility (screen readers)** | ❌ | ✅ AccessKit | ⚠️ experimental (AccessKit) | ⚠️ in progress | ⚠️ limited | ⚠️ in progress | ✅ the most mature |
| **IME / multilingual text input** | ❌ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ✅ |
| **Maturity / ecosystem** | ❌ 0.1.0, young | ✅ | ⚠️ | ⚠️ young, but commercially backed | ✅ | ⚠️ small community | ✅ 30 years, everything exists |
| **Documentation** | ⚠️ README + docs/ + specs | ✅ | ⚠️ | ✅ | ✅ | ⚠️ | ✅ |

## Development speed and syntax

| | **egui.cr** | **egui** | **iced** | **Slint** | **Fyne** | **Gio** | **Qt/QML** |
|---|---|---|---|---|---|---|---|
| **Syntax conciseness** | ✅ Ruby-like, blocks, type inference | ✅ | ⚠️ Elm model requires msg types and update | ⚠️ a separate DSL (a second language) | ⚠️ Go is verbose | ❌ low-level, manual layout | ❌ C++ is verbose; QML is a second language |
| **Compile speed / dev loop** | ✅ ~1.8 s dev build | ⚠️ `cargo check` fast, full builds slow | ❌ slow (generics + wgpu) | ⚠️ DSL is fast, host compilation is slow | ✅ fast | ✅ fast | ❌ C++ slow; QML interpreted |
| **Starter boilerplate** | ✅ one `App` class + a single `update` | ✅ | ⚠️ msg enum + update + view | ⚠️ .slint file + Rust glue | ✅ | ❌ | ❌ moc/signals/project files |
| **Hello-world binary size** | ✅ compact, static | ✅ | ⚠️ pulls in wgpu | ✅ | ⚠️ | ✅ the smallest of the Go ones | ❌ hundreds of MB of runtime |
| **Time to a presentable window with widgets** | ✅ one file → gallery | ✅ | ✅ | ✅ | ✅ | ⚠️ | ⚠️ |

## Syntax: a counter in three frameworks

The same minimal application — an increment button.

**egui.cr** — a signal + a binding, no manual synchronization:

```crystal
class Counter < Egui::App
  reactive count = 0

  def update(ctx)
    ctx.window("demo") do |ui|
      ui.label("Count: #{count}")
      self.count += 1 if ui.button("+1").clicked?
    end
  end
end
```

**egui (Rust)** — state is stored and mutated manually:

```rust
struct Counter { count: i32 }

impl eframe::App for Counter {
    fn update(&mut self, ctx: &egui::Context, _: &mut eframe::Frame) {
        egui::Window::new("demo").show(ctx, |ui| {
            ui.label(format!("Count: {}", self.count));
            if ui.button("+1").clicked() { self.count += 1; }
        });
    }
}
```

**iced (Rust)** — Elm: a message, an update, a view, each separate:

```rust
#[derive(Debug, Clone)]
enum Message { Increment }

fn update(count: &mut i32, message: Message) {
    match message { Message::Increment => *count += 1 }
}

fn view(count: &mut i32) -> iced::Element<Message> {
    column![
        text(format!("Count: {count}")),
        button("+1").on_press(Message::Increment),
    ].into()
}
```

## Verdict

- **egui.cr** — the fastest development loop and the most concise syntax
  in the list: signals + a CSS cascade + routing out of the box, the whole
  core in pure Crystal. Weak spots — youth (0.1.0), no accessibility, IME,
  mobile platforms or embedded.
- **egui (Rust)** — the closest relative and the most mature of the
  immediate-mode ones; wins on ecosystem and AccessKit, loses on compile
  speed and the lack of reactivity/CSS.
- **iced** — good for "serious" retained applications in Rust, but the Elm
  model adds boilerplate and builds are slow.
- **Slint** — the only one here with true live-preview and MCU support;
  the price is a separate DSL.
- **Fyne** — the easiest entry into Go GUI with mobile platforms; cgo and
  the lack of styling/reactive ergonomics limit it.
- **Gio** — ideologically pure (immediate mode + zero cgo), but
  low-level: much has to be built yourself.
- **Qt/QML** — functionally covers everything (except perhaps a terminal
  widget and a light binary), but it is the heaviest toolchain, the most
  verbose C++ and slow compilation.

The "web wrapper" category (Electron, Tauri, Wails) is excluded on
purpose: their runtime is a browser engine, not native rendering.
