# Icon providers

One folder per provider — an SVG icon set plus its LICENSE, resolved
at compile time by `Egui::Icon.from_file(provider, name)` (see
`src/egui/icon.cr`). Only the icons actually referenced by the code
are embedded into the binary; the folders on disk can hold the full
sets.

| Provider  | Folder       | License | Notes                                      |
|-----------|--------------|---------|--------------------------------------------|
| lucide    | `lucide/`    | ISC     | ~1850 stroke icons, 24×24 grid, 2px stroke |
| bootstrap | `bootstrap/` | MIT     | ~2000 fill icons, 16×16 viewBox (`fill="currentColor"`) |

## Usage

```crystal
# icons/lucide/save.svg — embedded at compile time, tinted with the
# theme foreground (the set's `currentColor`)
button = Egui::Button.new("Save")
  .icon(Egui::Icon.from_file(:lucide, :save, tint: ui.style.visuals.text_color))
```

Icon names map to file names with `_` → `-` (`:arrow_up` →
`arrow-up.svg`). The provider is always explicit; a missing icon is a
compile error. Adding a provider = adding a folder with `.svg` files
and its license file.

## Updating lucide

```sh
rake download:lucide
```

(What it does: a blobless sparse clone of
<https://github.com/lucide-icons/lucide.git>, then a full re-sync of
`icons/*.svg` + `LICENSE` into `icons/lucide/` — stale files from
upstream renames are removed.)

## Updating bootstrap

```sh
rake download:bootstrap
```

Same shape, upstream <https://github.com/twbs/icons.git> (MIT). Note:
bootstrap icons are fill-based (no stroke), and the Svg widget has no
polygon tessellation yet — a filled path renders as its stroked
outline, so glyphs show as contours rather than solid shapes.
