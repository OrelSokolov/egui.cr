# `.exml` — declarative UI documents for egui.cr: markup describes the
# page STRUCTURE (menus, panels, widgets, routed pages, modals), the
# binary owns the logic. The split mirrors HTML/CSS vs an application:
# ECSS carries style diffs, exml carries layout and widget trees, and
# the app reaches both through bindings — a store of named values the
# markup interpolates (`{name}`) and binds (`bind="name"`), plus named
# actions (`on_click="save"`) registered by the app.
#
# The parse happens ONCE (or on hot reload —
# `Document#reload_if_changed` stats the file like the ECSS session
# does) and is linear in file size (byte-based scan, see
# `parse_tags`); the per-frame cost is a tree walk dispatching tagged-union
# nodes to the regular egui.cr widgets, which immediate mode executes
# every frame anyway (measured in tmp/exml_proto.cr: a realistic page
# walks in tens of µs, ~0.15% of a 16 ms frame budget). What walk
# work can be done off the hot path IS: node attributes are flattened
# into fields at parse time (constants resolved once — numbers
# parsed, option lists split), repeat/component subtrees are re-pathed
# once per key instead of once per frame, and Runtime#interpolate
# caches a result while the slots it reads are unchanged — a
# steady-state frame allocates nothing for the markup chrome.
#
# Widget state (scroll, caret, selection) lives in the egui memory
# keyed by `Id`; node ids derive from the element's path in the
# document, so a hot-patched layout keeps every surviving widget's
# state — the property retained toolkits lose when a tree is swapped.
#
# What exml deliberately does NOT cover (the binary keeps it):
#   * derived values — the app computes stats and writes store slots;
#     there is no expression engine;
#   * anything needing new platform capabilities — the fixed widget
#     vocabulary is the price of "no interpreter in the loop".
#
# The window frame IS markup (the one deliberate exception from the
# old "caption hooks stay binary" rule): `<window-frame>` draws the
# stock chrome, `<window-frame-custom>` composes it — an explicit
# `<window-button type=…>` set plus arbitrary caption content — while
# the drag/resize/maximize BEHAVIOR stays inside Egui::WindowFrame
# (native move/resize handoff is not markup). The binary `.caption`
# hook remains for apps that don't use exml.
#
# Extensibility: any element name outside the built-in vocabulary
# parses as a Custom node and dispatches to a handler the APPLICATION
# registered — either per renderer instance (`Renderer#on`) or
# globally with the top-level `widget` sugar (every renderer sees
# it; an instance `#on` overrides). Custom handlers run BEFORE the
# built-in dispatch, so a registered name wins even when it IS a
# builtin (`on("label")` claims `<label>`) — no naming convention
# (hyphens) is required to add an element. Each developer extends
# the vocabulary per app — domain widgets, custom containers — with
# full access to node/ui/ctx/store and `render_each` for children;
# the module itself never needs editing.
#
# Vocabulary (lower-case elements, `name="value"` attributes):
#
#   page     id, title?, if?/unless?        routed full-window page
#   modal    id, title?, buttons="A|B|C",   routed modal page; the
#            delimiter?, on_button,          clicked label lands in
#            if?/unless?                     strings["_modal_button"]
#                                            before the action fires
#   menubar                                 ctx.menu_bar section
#   menu     label                          one menu_button dropdown
#   item     label, on_click, hint?         menu row (hint = hotkey)
#   central  id?                            ctx.central_panel
#   statusbar id?                           ctx.bottom_panel
#   row | column                           inline layout
#   form                                   validation scope (form.cr):
#                                          inputs inside register their
#                                          validity; button type="submit"
#                                          gates on_click on all of them
#   heading | label   text, if?/unless?, live?   live → request_repaint
#   button   text, on_click, if?/unless?, type? (type="submit" inside a
#            <form>: fires only through a valid form)
#   slider   bind, min, max, on_change?
#   checkbox bind, text, on_change?
#   progress bind, text?
#   input    bind, hint?, focus_id?, on_change?   single-line editor
#            numeric?, trim?, required?, pattern? — the HTML constraint
#            attrs; an invalid field paints `text_edit:invalid` once
#            touched or after a blocked submit (pattern compiles at
#            parse time; a bad regex is a parse error)
#   textarea bind, hint?, rows, frame, editor_id? multi-line; editor_id
#            interpolates and switches the child-Ui (per-tab editors),
#            auto-focusing a CHANGED id (focus follows the tab)
#   combo    bind, options="A|B|C", delimiter?, on_change?
#            :options="{list}" — a list slot (rt.lists) instead of
#            a literal split; the dynamic counterpart, same push
#            model as <repeat over=…> rows
#   openfile bind, text?, text_choosing?, text_done?,  native file
#            filters?, title?, directory?, multiple?,    dialog (never
#            label_class?, on_change?                   blocks the
#   savefile …+ default_name?                          frame) + a
#            path label. The chosen path lands in the bound string
#            slot; "bind/choosing" (bool) is true while the dialog is
#            up; a cancel keeps the old value. Button text walks the
#            three states (idle → choosing → chosen). filters are
#            pipe-separated globs ("*.png|*.jpg"); the label (class
#            "file-label", or label_class) shows the path and turns
#            off with the `visible: false` style key — which ANY
#            class-carrying element understands (see style_visible?)
#   separator
#   repeat   for="doc"?, in="items", key="id"?,    the v-for (Python
#            index="i"?                             reading order): rows
#            from a list slot (rt.rows["…"]), one scope per row — the
#            row's fields as {doc.field}, "_i" the row index (index=
#            renames it, v-for's `(item, i)`); actions fired from a
#            row write "_i" to the root store first; `key` gives
#            stable widget ids across reorders
#   markdown text, base_dir?                     the markdown widget
#   window-frame style?, title?                  the stock client-side
#                                               window chrome — one
#                                               line, the style's
#                                               default caption; put
#                                               it first in the page
#   window-frame-custom style?, title?, height?  the composable frame:
#                                               <window-button> children
#                                               name the caption button
#                                               set, every other child
#                                               renders into the caption
#                                               (tabs, a search strip)
#   window-button type, on_click?                one caption button —
#                                               minimize/maximize/close;
#                                               on_click replaces the
#                                               native action
#   formula  tex, size?, display?, color?        LaTeX via mathjax.cr —
#            OPT-IN: require "egui/exml_formula" (a dev dependency,
#            registered as a global `widget`, not a builtin kind)
#
# Widgets carrying `id="name"` register their Response in the
# renderer's ref registry for the frame — the app reads them after
# rendering (`renderer.ref("name")`: rect, clicked?, hovered?, …).
# A component's use-site ATTRIBUTES become its props: they seed the
# site's scope as slots (interpolated against the enclosing store,
# before `setup`); structural `if`/`unless`/`id` are not props.
#
# Values interpolate from the store into ANY attribute: editor_id=
# "notepad/doc/{selected}" renders the active tab's editor.
#
# Partials — plain parse-time composition, no parameters, no scopes:
#
#   <partial id="app_menu"><menubar>…</menubar></partial>
#   <page id="root/root"><use partial="app_menu"/> … </page>
#
# `<use>` splices the partial's children in place while parsing; the
# spliced subtree is re-pathed under the USE site, so two `<use>` of
# one partial never share widget ids (state stays independent).
# Partial-in-partial works; cycles are detected statically and the
# recursive branch is dropped with a warning.
#
# Vue directive spellings parse as ALIASES and desugar to the
# canonical attributes above: `v-if`/`v-show` → `if=`, `v-model` →
# `bind=`, `v-text` → `text=`, `@click`/`v-on:click` → `on_click=`,
# `:title`/`v-bind:title` → `title="{title}"`, `v-else` → the previous
# sibling's inverted condition, `v-for="item in items"` (with `:key`)
# → a synthesized `<repeat>` wrapper, `ref="name"` → `id="name"` (the
# template-ref registry), `v-model.number`/`.trim` → `numeric=`/
# `trim=`, `@keyup.enter="save"` → `hotkey="enter"` + `on_keyup=`
# (window-global, the regular HotkeyMap), and `<template>` — a
# parse-time group wrapper whose children splice into the parent (the
# group's `v-if`/`v-else` gate copied onto each child; `<template
# v-for>` repeats the whole group). The values stay OURS — a bare
# slot/action/field name, never a JS expression (a warned parse issue,
# `Exml.warnings`). SPEC.md §7 carries the full subset table.
#
# `Exml.validate` lints a parsed document — element vocabulary,
# attribute names/shapes, required attributes — so markup/enum drift
# is caught at build/test time (the spec suite lints assets/*.exml),
# not when the widget fails to render.

module Egui
  module Exml
    # One element kind per enum value — the walk dispatches on this,
    # never on strings. `Custom` is the extension point: any element
    # name outside KIND_BY_NAME parses as Custom and dispatches to a
    # handler the app registered on its Renderer (`Renderer#on`) —
    # the vocabulary is open per application, no module edits needed.
    # A handler registered for a BUILT-IN name overrides the builtin
    # (custom dispatch runs first — see Renderer#render_body).
    enum Kind
      Page; Modal; MenuBar; Menu; MenuItem; Central; Statusbar
      Row; Column; Box; Heading; Label; Button; Slider; Checkbox
      Separator; Progress; Input; Textarea; Combo; Toggle
      OpenFile; SaveFile; Custom
      Partial; Use; Repeat; Markdown; FlexItem; Template
      WindowFrame; WindowFrameCustom; WindowButton; Form
    end

    CONTAINERS = {Kind::Page, Kind::Modal, Kind::MenuBar, Kind::Menu,
                  Kind::Central, Kind::Statusbar, Kind::Row, Kind::Column,
                  Kind::Box, Kind::Repeat, Kind::Form}

    # Element-name → Kind (enum `parse?` is case-sensitive and has no
    # idea about aliases, so the map carries both). "exml" is the
    # grouping wrapper — a column, unwrapped at the top level.
    # "partial"/"use" are parse-time only: never reach the renderer.
    KIND_BY_NAME = {
      "page" => Kind::Page, "modal" => Kind::Modal,
      "menubar" => Kind::MenuBar, "menu" => Kind::Menu,
      "item" => Kind::MenuItem, "menuitem" => Kind::MenuItem,
      "central" => Kind::Central, "central_panel" => Kind::Central,
      "statusbar" => Kind::Statusbar, "bottom_panel" => Kind::Statusbar,
      "row" => Kind::Row, "column" => Kind::Column,
      "box" => Kind::Box,
      "form" => Kind::Form,
      "heading" => Kind::Heading, "label" => Kind::Label,
      "button" => Kind::Button, "slider" => Kind::Slider,
      "checkbox" => Kind::Checkbox, "separator" => Kind::Separator,
      "progress" => Kind::Progress, "progressbar" => Kind::Progress,
      "input" => Kind::Input, "textarea" => Kind::Textarea,
      "combo" => Kind::Combo, "combobox" => Kind::Combo,
      # `<toggle>` — the switch-style checkbox (ToggleButton)
      "toggle" => Kind::Toggle,
      # `<openfile>`/`<savefile>` — a button driving the native file
      # dialog plus a label with the bound path (see render_file_picker)
      "openfile" => Kind::OpenFile, "savefile" => Kind::SaveFile,
      "exml" => Kind::Column,
      "partial" => Kind::Partial, "use" => Kind::Use,
      "repeat" => Kind::Repeat, "markdown" => Kind::Markdown,
      # `<flex-item>` — per-child flex factors inside a flex box
      # (`<box flex="true">`): `<flex-item grow="1" order="-1">…`.
      "flex-item" => Kind::FlexItem, "fitem" => Kind::FlexItem,
      # `<template>` — parse-time group wrapper (Vue's): spliced away
      # by `desugar_vue_tree`, never reaches the renderer.
      "template" => Kind::Template,
      # `<window-frame>` / `<window-frame-custom>` — the client-side
      # window chrome (Egui::WindowFrame) as markup: the stock one
      # draws the style's default caption (title + buttons); the
      # custom one takes an explicit `<window-button>` set plus
      # arbitrary caption content (tabs, a search strip).
      "window-frame" => Kind::WindowFrame,
      "window-frame-custom" => Kind::WindowFrameCustom,
      "window-button" => Kind::WindowButton,
    } of String => Kind

    # One parsed element: kind + attributes + children + the stable
    # document path used for egui `Id`s. `name` keeps the raw element
    # name — the dispatch key for Custom elements.
    #
    # The attributes the built-in vocabulary reads are FLATTENED into
    # fields here — once, at parse time — and constants are resolved
    # while at it (numbers parsed, option/button lists split): the
    # per-frame walk reads fields instead of hashing attr keys and
    # never re-parses. `#attrs` keeps the raw map for custom-element
    # handlers, the linter and the parse-time passes; nothing mutates
    # it after parse.
    class Node
      getter kind : Kind
      getter name : String
      getter attrs : Hash(String, String)
      getter children : Array(Node)
      getter path : String

      # structural
      getter if_cond : String?            # if= (raw, may hold {slots})
      getter unless_cond : String?        # unless=
      getter ref_name : String?           # id=, non-empty — refs, route ids
      getter panel_id : String            # central/statusbar egui panel id
      # page/modal
      getter title_attr : String?
      getter buttons_list : Array(String)
      getter on_button : String?
      # list attrs — the `delimiter=` override for options/buttons splits
      getter list_delimiter : String?
      # menus
      getter label_attr : String?
      getter hint_attr : String?
      getter on_click : String?
      # text widgets
      getter text_attr : String?
      getter live : Bool
      getter base_dir : String?
      # bound widgets
      getter bind_key : String?
      getter on_change : String?
      getter slider_min : Float64
      getter slider_max : Float64
      getter focus_id : String?
      getter editor_id : String?
      getter rows_count : Int32
      getter framed : Bool
      getter combo_options : Array(String)
      # validation (`<input required pattern>` / `<button type=submit>`
      # inside `<form>` — see form.cr): required is the HTML boolean,
      # pattern compiles ONCE here (an invalid regex is a parse error,
      # never a runtime surprise), submit marks a form-gated button.
      getter input_required : Bool
      getter input_pattern : Regex?
      getter button_type : String?
      # `:options="{list}"` — the bound variant: a list slot name the
      # app publishes (rt.lists), nil for a literal options= split
      getter options_key : String?
      # repeat
      getter repeat_for : String?
      getter repeat_in : String?
      getter repeat_key : String?
      getter repeat_index_alias : String? # index= — v-for's (item, i)
      # box
      getter box_row : Bool
      getter box_wrap : Bool
      getter box_fill : Color32 | Gradient?
      getter box_stroke : Color32?
      getter box_rounding : Float64
      getter box_padding : Float64?
      getter box_class : String?
      # flex box (`<box flex="true">`) — the container modes (CSS
      # spellings, parsed by Flex.parse_* at render time) plus the
      # definite extents a column flex needs
      getter box_flex : Bool
      getter box_justify : String?
      getter box_align : String?
      getter box_gap : Float64?
      getter box_width : String?
      getter box_height : String?
      # flex item (`<flex-item>`) — the per-child factors
      getter flex_grow : Float64
      getter flex_shrink : Float64
      getter flex_basis : String?
      getter flex_order : Int32
      getter flex_align_self : String?
      # input extras — v-model's .number/.trim (`numeric` writes the
      # float slot, `trim` strips the write-back)
      getter numeric : Bool
      getter trim : Bool
      # hotkey — v-on key modifiers (`@keyup.enter`): the KEY spelling
      # plus the key event whose action it fires (window-global)
      getter hotkey_attr : String?
      getter on_key_event : String?
      # file pickers (`<openfile>`/`<savefile>`) — the per-state button
      # texts, the pipe-separated filter globs, the dialog plumbing and
      # the class of the path label ("file-label" when not given).
      # file_multiple: `<openfile multiple>` — pick several files; the
      # bound string slot holds the newline-JOINED paths.
      getter file_choosing_text : String?
      getter file_done_text : String?
      getter file_filters : Array(String)
      getter file_label_class : String?
      getter file_default_name : String?
      getter file_directory : String?
      getter? file_multiple : Bool
      # window frame (`<window-frame>`/`<window-frame-custom>`) — the
      # style NAME (a WindowFrame::STYLE_NAMES key, interpolatable for
      # live theme switching) and the custom frame's caption-height
      # override; `<window-button type=…>` — the button name
      getter frame_style : String?
      getter frame_height : Float64?
      getter button_type : String?

      @children_under : Hash(String, Array(Node))? = nil
      # Memoized Id of #path (push-дифф §8 (а)): handlers and the
      # renderer fold Id.from(path) per frame — one path-string hash
      # per node lifetime instead. Rows re-path ONCE per key change
      # (#children_under), so the memo stays valid.
      @id : Id? = nil

      def id : Id
        @id ||= Id.from(@path)
      end

      def initialize(@kind, @name, @attrs, @children, @path)
        @if_cond = @attrs["if"]?
        @unless_cond = @attrs["unless"]?
        id = @attrs["id"]?
        @ref_name = id.try { |s| s.empty? ? nil : s }
        @panel_id = id || (@kind.central? ? "central_panel" : "bottom_panel")
        @title_attr = @attrs["title"]?
        @list_delimiter = @attrs["delimiter"]?.try { |d| d.empty? ? nil : d }
        @buttons_list = Exml.split_list(@attrs["buttons"]?,
          @list_delimiter || "|")
        @on_button = @attrs["on_button"]?
        @label_attr = @attrs["label"]?
        @hint_attr = @attrs["hint"]?
        @on_click = @attrs["on_click"]?
        @text_attr = @attrs["text"]?
        @live = @attrs["live"]? == "true"
        @base_dir = @attrs["base_dir"]?
        @bind_key = @attrs["bind"]?
        @on_change = @attrs["on_change"]?
        @slider_min = @attrs["min"]?.try(&.to_f?) || 0.0
        @slider_max = @attrs["max"]?.try(&.to_f?) || 1.0
        @focus_id = @attrs["focus_id"]?
        @editor_id = @attrs["editor_id"]?
        @rows_count = @attrs["rows"]?.try(&.to_i?) || 8
        @framed = @attrs["frame"]? != "false"
        @options_key = Exml.slot_ref?(@attrs["options"]?)
        @combo_options = @options_key ? Array(String).new
          : Exml.split_list(@attrs["options"]?, @list_delimiter || "|")
        @repeat_for = @attrs["for"]?
        @repeat_in = @attrs["in"]?
        @repeat_key = @attrs["key"]?
        @repeat_index_alias = @attrs["index"]?
        @box_row = @attrs["direction"]? == "row"
        @box_wrap = @attrs["wrap"]? != "false"
        @box_fill = Exml.parse_box_color(@attrs["fill"]?)
        # border stays a plain color — gradients are a fill concern
        @box_stroke = @attrs["border"]?.try { |b| Exml.parse_box_stroke(b) }
        @box_rounding = @attrs["rounding"]?.try(&.to_f?) || 6.0
        @box_padding = @attrs["padding"]?.try(&.to_f?)
        @box_class = @attrs["class"]?
        @box_flex = @attrs["flex"]? == "true"
        @box_justify = @attrs["justify"]?
        @box_align = @attrs["align"]?
        @box_gap = @attrs["gap"]?.try(&.to_f?)
        @box_width = @attrs["width"]?
        @box_height = @attrs["height"]?
        @flex_grow = @attrs["grow"]?.try(&.to_f?) || 0.0
        @flex_shrink = @attrs["shrink"]?.try(&.to_f?) || 1.0
        @flex_basis = @attrs["basis"]?
        @flex_order = @attrs["order"]?.try(&.to_i?) || 0
        @flex_align_self = @attrs["align"]?
        @numeric = @attrs["numeric"]? == "true"
        @trim = @attrs["trim"]? == "true"
        @input_required = @attrs["required"]? == "true"
        @input_pattern = @attrs["pattern"]?.try do |p|
          begin
            Regex.new(p)
          rescue e : Regex::Error
            raise ArgumentError.new(
              %(<input pattern="#{p}"> is not a valid regex: #{e.message}))
          end
        end
        @button_type = @attrs["type"]?
        @hotkey_attr = @attrs["hotkey"]?
        @on_key_event = @attrs["on_keyup"]? || @attrs["on_keydown"]?
        @file_choosing_text = @attrs["text_choosing"]?
        @file_done_text = @attrs["text_done"]?
        @file_filters = Exml.split_list(@attrs["filters"]?, "|")
        @file_label_class = @attrs["label_class"]?
        @file_default_name = @attrs["default_name"]?
        @file_directory = @attrs["directory"]?
        @file_multiple = @attrs.has_key?("multiple")
        @frame_style = @attrs["style"]?
        @frame_height = @attrs["height"]?.try(&.to_f?)
        @button_type = @attrs["type"]?
      end

      def container? : Bool
        CONTAINERS.includes?(@kind)
      end

      # Children re-pathed under `prefix`, memoized: repeat rows and
      # component use sites re-render every frame, and repathing per
      # frame allocated a fresh subtree per row per frame. Distinct
      # prefixes are bounded (row keys, use sites); a re-parse builds
      # fresh Nodes, so a hot-reloaded tree never sees stale caches.
      def children_under(prefix : String) : Array(Node)
        cache = (@children_under ||= {} of String => Array(Node)).not_nil!
        cache[prefix] ||= children.map { |c| Exml.repath(c, prefix) }
      end
    end

    # ── parser ─────────────────────────────────────────────────────────

    # `fill=`/`border=` color for `<box>`: #rgb / #rrggbb / #rrggbbaa,
    # or a full gradient spelling (`linear-gradient(…)`/`radial-
    # gradient(…)`, the same grammar as the ECSS `background-gradient`
    # key) — parsed once at Node build time (nil for absent or
    # malformed — the linter flags the malformed ones at validate time).
    def self.parse_box_color(s : String?) : Color32 | Gradient?
      return nil unless s
      if (g = Gradient.parse?(s))
        g
      elsif s.starts_with?('#')
        parse_hex_color(s)
      else
        nil
      end
    end

    private def self.parse_hex_color(s : String) : Color32?
      hex = s[1..]
      hex = hex.chars.map { |c| "#{c}#{c}" }.join if hex.size == 3
      return nil unless hex.size == 6 || hex.size == 8
      vals = hex.chars.map { |c| c.to_i?(16) || (return nil) }
      pair = ->(i : Int32) { vals[i] * 16 + vals[i + 1] }
      a = hex.size == 8 ? pair.call(6).to_u8 : 255u8
      Color32.new(pair.call(0).to_u8, pair.call(2).to_u8,
        pair.call(4).to_u8, a)
    end

    # `border=` is a plain color key (nil for malformed/absent).
    def self.parse_box_stroke(s : String) : Color32?
      return nil unless s.starts_with?('#')
      parse_hex_color(s)
    end

    # List-valued attributes (`options=`, `buttons=`) split on their
    # default separator `|` unless the element carries `delimiter="…"`
    # (any string, a comma or space included); blank items drop out
    # either way.
    def self.split_list(s : String?, delim : String) : Array(String)
      return [] of String unless s
      s.split(delim).map(&.strip).reject(&.empty?)
    end

    # An options= value of the single-slot form "{name}" — the
    # desugared `:options="name"` — BINDS a list slot (rt.lists)
    # instead of splitting a literal; nil for plain literal lists.
    def self.slot_ref?(s : String?) : String?
      return nil unless s
      return nil unless s.starts_with?('{') && s.ends_with?('}')
      inner = s[1..-2]
      inner.matches?(/^[a-zA-Z_][a-zA-Z0-9_.]*$/) ? inner : nil
    end

    # ── codegen (plans/NativeHTML.md §6, Route A) ──────────────────────
    #
    # Serialize a Document as Crystal source — the literal
    # `Array(Node)` tree the parser would have built, one renderer for
    # both. Only the five constructor arguments are emitted (kind,
    # name, attrs, children, path); every flattened field re-derives
    # inside `Node#initialize`, so the generated literals can never
    # drift from the parser. `egui-gen` (scripts/egui_gen.cr) wraps
    # this as a build step.

    def self.emit_crystal(doc : Document, source : String? = nil,
                          module_name : String = "EguiGen") : String
      src = source || doc.path || "markup"
      String.build do |io|
        io << "# Generated by egui-gen from " << src
        io << " — DO NOT EDIT; regenerate instead:\n"
        io << "#   crystal run scripts/egui_gen.cr -- " << src
        io << " <this file>\n"
        io << "# The literal Node tree of the parser's output — the XML\n"
        io << "# parse disappears from runtime (one renderer, two\n"
        io << "# declaration front-ends; plans/NativeHTML.md §6).\n"
        io << "module " << module_name << "\n"
        io << "  SOURCE = " << src.inspect << "\n"
        io << "  DOCUMENT = begin\n"
        io << "    pages = " << emit_nodes(doc.pages, 2) << "\n"
        if doc.partials.empty?
          io << "    partials = {} of String => Egui::Exml::Node\n"
        else
          io << "    partials = {\n"
          doc.partials.each do |name, node|
            io << "      " << name.inspect << " => " \
              << emit_node(node, 3) << ",\n"
          end
          io << "    } of String => Egui::Exml::Node\n"
        end
        io << "    Egui::Exml::Document.new(pages, partials)\n"
        io << "  end\n\n"
        io << "  def self.document : Egui::Exml::Document\n"
        io << "    DOCUMENT\n"
        io << "  end\n"
        io << "end\n"
      end
    end

    def self.emit_nodes(nodes : Array(Node), indent : Int32) : String
      return "[] of Egui::Exml::Node" if nodes.empty?
      String.build do |io|
        io << "[\n"
        nodes.each { |n| io << emit_node(n, indent + 1) << ",\n" }
        io << ("  " * indent) << "] of Egui::Exml::Node"
      end
    end

    def self.emit_node(node : Node, indent : Int32) : String
      ind = "  " * indent
      String.build do |io|
        io << ind << "Egui::Exml::Node.new(\n"
        io << ind << "  Egui::Exml::Kind::" << node.kind << ",\n"
        io << ind << "  " << node.name.inspect << ",\n"
        io << ind << "  " << emit_attrs(node.attrs) << ",\n"
        if node.children.empty?
          io << ind << "  [] of Egui::Exml::Node,\n"
        else
          io << ind << "  [\n"
          node.children.each do |c|
            io << emit_node(c, indent + 2) << ",\n"
          end
          io << ind << "  ] of Egui::Exml::Node,\n"
        end
        io << ind << "  " << node.path.inspect << ")"
      end
    end

    private def self.emit_attrs(attrs : Hash(String, String)) : String
      return "{} of String => String" if attrs.empty?
      String.build do |io|
        io << "{\n"
        attrs.each do |k, v|
          io << "  " << k.inspect << " => " << v.inspect << ",\n"
        end
        io << "  } of String => String"
      end
    end

    # Parses markup into a Document. Lenient like the ECSS parser: a
    # half-typed live-edited file costs a STDERR warning and a skipped
    # piece, never a crash. Top level is `<page>`/`<modal>` elements
    # (optionally wrapped in one grouping element, e.g. `<exml>`).
    def self.parse(text : String) : Document
      root_children = parse_tags(text)

      # unwrap a single grouping element (<exml>…</exml>)
      if root_children.size == 1 && !root_children[0].kind.page? &&
         !root_children[0].kind.modal?
        root_children = root_children[0].children
      end

      # Partials: top-level <partial id="…"> definitions — templates,
      # never rendered where defined. Everything else top-level must
      # be a page/modal.
      partials = {} of String => Node
      pages = [] of Node
      root_children.each do |top|
        if top.kind.partial?
          if (pid = top.attrs["id"]?)
            partials[pid] = top
          else
            STDERR.puts "exml: <partial> without id — ignored"
          end
        elsif top.kind.page? || top.kind.modal?
          pages << top
        else
          STDERR.puts "exml: top-level <#{top.name}> ignored" \
                      " (only page/modal/partial allowed)"
        end
      end

      # <use partial="…"> → splice the partial's children here, re-pathed
      # under the use site (two uses of one partial → independent widget
      # ids → independent state). Cycles are detected statically: the
      # expansion stack holds the partials currently being expanded.
      pages.each { |p| expand(p, partials, [] of String) }

      Document.new(pages, partials)
    end

    # Recursively replace <use> nodes in `node.children` with the
    # referenced partial's (already expanded) children. Warn-once per
    # problem name: a missing partial and a cycle both drop the branch.
    private def self.expand(node : Node, partials : Hash(String, Node),
                            stack : Array(String)) : Nil
      replaced = [] of Node
      node.children.each do |child|
        if child.kind.use?
          pid = child.attrs["partial"]?
          if !pid
            STDERR.puts "exml: <use> without partial= — dropped"
          elsif (partial = partials[pid]?).nil?
            STDERR.puts "exml: <use partial=\"#{pid}\"> — no such partial, dropped"
          elsif stack.includes?(pid)
            STDERR.puts "exml: partial \"#{pid}\" uses itself" \
                        " (#{(stack + [pid]).join(" → ")}) — branch dropped"
          else
            stack.push(pid)
            expand(partial, partials, stack)
            stack.pop
            partial.children.each do |spliced|
              replaced << repath(spliced, child.path)
            end
          end
        else
          expand(child, partials, stack)
          replaced << child
        end
      end
      node.children.replace(replaced)
    end

    # Deep-copy a spliced subtree under a new path prefix: fresh Nodes
    # (fresh ids — widget state must not leak between use sites), same
    # attrs/children structure. The SAME prefix goes to every node —
    # each node's original path is already unique inside the partial,
    # prefix + original path is the re-rooted identity.
    def self.repath(node : Node, prefix : String) : Node
      Node.new(node.kind, node.name, node.attrs,
        node.children.map { |c| repath(c, prefix) },
        "#{prefix}#{node.path}")
    end

    # An attribute NAME: the canonical `[a-z_][a-z0-9_]*` (HTML rules)
    # widened with the Vue directive spellings — `v-if`,
    # `v-model.number`, `v-bind:title`, `v-on:click`, `:title`, `@click`
    # (plans/vue-aliases.md). They desugar at parse (`desugar_vue_*`
    # below); the renderer, the linter and the codegen never see one.
    ATTR_NAME = /(?:v-[a-zA-Z][a-zA-Z-]*(?:[:.][a-zA-Z_][a-zA-Z0-9_.-]*)?|[@:]?[a-zA-Z_][a-zA-Z0-9_.-]*)/

    # The tag-attr regexes, hoisted: an interpolated regex literal
    # (`/#{ATTR_NAME}…`) constructs a fresh Regex — a PCRE2 JIT
    # compile — on EVERY evaluation, and per tag that dwarfed the
    # scan itself. ATTR_NAME holds only non-capturing groups, so the
    # outer parens stay m[1].
    ATTR_VALUE_RE = Regex.new("(#{ATTR_NAME.source})\\s*=\\s*\"([^\"]*)\"")
    STRIP_ATTR_RE = Regex.new("\\s*(#{ATTR_NAME.source})\\s*=\\s*\"[^\"]*\"")

    # `<name key="value" …>` → {downcased name, attrs}. Entity escapes
    # are resolved in attribute values.
    private def self.parse_tag(inner : String)
      parts = inner.split(/\s+/, 2)
      name = parts[0]?.try(&.downcase)
      return {nil, nil} unless name
      attrs = {} of String => String
      if rest = parts[1]?
        # Attribute names: ATTR_NAME (canonical HTML names — `c1=`/
        # `s20=` are valid; a digit-less class silently dropped them as
        # "junk" — plus the Vue directive spellings). The valueless
        # boolean attributes of the subset — `v-else`, `multiple` on
        # <openfile> — are picked out of the remainder below.
        rest.scan(ATTR_VALUE_RE) do |m|
          attrs[m[1].downcase] = unescape(m[2])
        end
        stray = rest.gsub(STRIP_ATTR_RE, "").strip
        if stray =~ /\bv-else\b/
          attrs["v-else"] = "true"
          stray = stray.gsub(/\bv-else\b/, "").strip
        end
        if stray =~ /\bmultiple\b/
          attrs["multiple"] = "true"
          stray = stray.gsub(/\bmultiple\b/, "").strip
        end
        STDERR.puts "exml: junk in <#{name}> tag: #{stray}" unless stray.empty?
      end
      {name, attrs}
    end

    # ── Vue directive aliases (plans/vue-aliases.md) ──────────────────
    #
    # The Vue WRITING of directives, desugared to canonical form while
    # parsing: after desugar the tree IS canonical, so `validate`,
    # codegen and hot reload never notice an alias. The formula is
    # "Vue's form, our values" — a directive's value is a bare
    # slot/action/field name, never a JS expression; an expression
    # value warns (collected in `warnings`) instead of failing
    # silently. Canonical spellings stay valid forever — the aliases
    # are purely additive.

    # Parse-time desugar diagnostics (also printed to STDERR); cleared
    # at every parse. Tooling reads this, specs assert on it.
    class_property warnings = [] of String

    private def self.vue_warn(msg : String) : Nil
      warnings << msg
      STDERR.puts "exml: #{msg}"
    end

    private def self.expr_warn(path : String, key : String,
                               value : String) : Nil
      vue_warn(%(#{path}: #{key}="#{value}" — expressions are not) \
               %( supported; publish a slot and use its name))
    end

    # A bare slot/action reference — `name`, `doc.field`, optionally
    # wrapped in `{}` (the canonical if= spelling). Anything else
    # (spaces, operators, calls) is a JS expression — out of subset.
    private def self.bare_ref?(value : String) : Bool
      v = value.starts_with?('{') && value.ends_with?('}') ? value[1..-2] : value
      !v.empty? && v.matches?(/^[a-zA-Z_][a-zA-Z0-9_.]*$/)
    end

    # Quick gate: only Vue-prefixed keys (and `ref`, the one bare-name
    # alias) need the desugar scan — canonical documents skip it
    # entirely.
    private def self.vue_attrs?(attrs : Hash(String, String)) : Bool
      attrs.keys.any? { |k|
        k.starts_with?("v-") || k.starts_with?(':') ||
          k.starts_with?('@') || k == "ref"
      }
    end

    # Per-tag attribute desugar, right after the path is known
    # (diagnostics carry it). `v-for`/`v-else` survive for the tree
    # pass (`desugar_vue_tree`).
    private def self.desugar_vue_attrs(attrs : Hash(String, String),
                                       path : String) : Nil
      renames = [] of Tuple(String, String, String) # old, new, value
      drops = [] of String

      attrs.each do |key, value|
        case key
        when "v-if", "v-show"
          # v-show ≡ if=: rendering is skipped but widget memory lives
          # on by Id-path — Vue's display:none semantics, state kept
          expr_warn(path, key, value) unless bare_ref?(value)
          renames << {key, "if", value}
        when "v-model"
          expr_warn(path, key, value) unless bare_ref?(value)
          renames << {key, "bind", value}
        when "ref"
          # Vue's template-ref IS the ref registry (`renderer.ref`) —
          # the same thing `id=` feeds; a real id= wins
          if attrs.has_key?("id")
            vue_warn(%(#{path}: ref="#{value}" — id= is already set;) \
                     %( ref dropped))
            drops << key
          else
            renames << {key, "id", value}
          end
        when "v-text"
          expr_warn(path, key, value) unless bare_ref?(value)
          renames << {key, "text",
                      value.includes?('{') ? value : "{#{value}}"}
        when .starts_with?("v-model.")
          expr_warn(path, key, value) unless bare_ref?(value)
          # v-model modifiers (plans/vue-aliases2.md): `.number` binds
          # the FLOAT slot, `.trim` strips the write-back — the rest
          # (`.lazy` above all: on_change is already event-shaped)
          # warn + drop
          renames << {key, "bind", value}
          key[8..].split('.').each do |mod|
            case mod
            when "number" then renames << {key, "numeric", "true"}
            when "trim"   then renames << {key, "trim", "true"}
            when "lazy"
              vue_warn(%(#{path}: #{key} — .lazy is not in the subset) \
                       %( (on_change already fires on commit); dropped))
            else
              vue_warn(%(#{path}: #{key} — v-model modifiers are not) \
                       %( in the subset; dropped))
            end
          end
        when "v-for", "v-else"
          # consumed by the tree pass below
        else
          if key.starts_with?(':') || key.starts_with?("v-bind:")
            prop = key.starts_with?(':') ? key[1..] : key[7..]
            if prop.empty?
              drops << key
            elsif prop == "key" && attrs.has_key?("v-for")
              # v-for's :key names the row FIELD to key on — the
              # `<var>.` prefix is the row variable, dropped
              if (dot = value.index('.'))
                renames << {key, "key", value[(dot + 1)..]}
              else
                vue_warn(%(#{path}: :key="#{value}" — expected) \
                         %( "<var>.<field>", the field being the row key))
                drops << key
              end
            elsif value.to_f? || %w(true false).includes?(value)
              vue_warn(%(#{path}: #{key}="#{value}" — a literal; write) \
                       %( #{prop}="#{value}" directly))
              renames << {key, prop, value}
            elsif bare_ref?(value)
              renames << {key, prop, "{#{value}}"}
            else
              expr_warn(path, key, value)
              drops << key
            end
          elsif key.starts_with?('@') || key.starts_with?("v-on:")
            event = key.starts_with?('@') ? key[1..] : key[5..]
            parts = event.split('.')
            base = parts[0]
            mods = parts[1..]
            expr_warn(path, key, value) unless bare_ref?(value)
            if mods.empty?
              renames << {key, "on_#{base}", value} unless base.empty?
            elsif {"keyup", "keydown"}.includes?(base) &&
                  (hk = Hotkey.parse?(mods.join('+')))
              # Key events' dotted suffix is the KEY (a `Hotkey`
              # spelling — `@keyup.enter`, `@keyup.ctrl.enter`): the
              # key fires the action WINDOW-globally, no focus needed
              renames << {key, "hotkey", mods.join('+')}
              renames << {key, "on_#{base}", value}
            else
              vue_warn(%(#{path}: #{key} — event modifiers are not in) \
                       %( the subset; using the bare "#{base}" event))
              renames << {key, "on_#{base}", value} unless base.empty?
            end
          elsif key.starts_with?("v-")
            vue_warn(%(#{path}: #{key} is not in the Vue subset) \
                     %( (SPEC.md §7) — dropped))
            drops << key
          end
        end
      end

      drops.each { |k| attrs.delete(k) }
      renames.each do |old, neu, v|
        attrs.delete(old)
        attrs[neu] = v
      end
    end

    # The second alias half — a parse-time tree rewrite (the precedent
    # is `expand`/`repath`): `v-else` mirrors the previous sibling's
    # `if=`/`unless=`, and `v-for` replaces the node with a synthesized
    # `<repeat>` wrapper taking the node's path. Canonical documents
    # pass through untouched. Rewrites REBUILD nodes (flattened fields
    # are set in `Node#initialize` — mutating attrs afterwards would
    # leave them stale). Runs before partial expansion: v-for on `<use>`
    # is not in the subset (warn + the bare element survives).
    private def self.desugar_vue_tree(nodes : Array(Node)) : Nil
      nodes.each { |n| desugar_vue_tree(n.children) }

      nodes.each_with_index do |node, i|
        next unless node.attrs.has_key?("v-else")
        attrs = node.attrs.dup
        attrs.delete("v-else")
        prev = i > 0 ? nodes[i - 1] : nil
        if (cond = prev.try &.if_cond)
          attrs["unless"] = cond
        elsif (cond = prev.try &.unless_cond)
          attrs["if"] = cond
        else
          vue_warn(%(#{node.path}: v-else without a preceding if=/) \
                   %(unless= sibling — dropped))
        end
        nodes[i] = Node.new(node.kind, node.name, attrs,
          node.children, node.path)
      end

      nodes.each_with_index do |node, i|
        next unless node.attrs.has_key?("v-for")
        nodes[i] = wrap_v_for(node)
      end

      # Last pass: `<template>` — a parse-time GROUP wrapper (Vue's):
      # no node of its own, children splice into the parent in place.
      # A group `if=`/`unless=` (v-if/v-else on the template) is
      # copied onto every child — each gate is independent, `visible?`
      # already checks both. Children KEEP their parsed paths (the
      # template's path segment namespaces them), so splicing never
      # collides with a same-named sibling and no path shifts.
      spliced = [] of Node
      nodes.each do |node|
        if node.kind.template?
          node.children.each { |c| spliced << copy_group_gate(node, c) }
        else
          spliced << node
        end
      end
      nodes.replace(spliced)
    end

    # Copy a `<template>` group's if=/unless= gate onto one child. A
    # child's OWN gate of the same kind wins (the AND of two slots is
    # an expression — not expressible; warned, the plan's "no
    # half-properties" rule).
    private def self.copy_group_gate(group : Node, child : Node) : Node
      return child if group.if_cond.nil? && group.unless_cond.nil?
      attrs = child.attrs.dup
      if (cond = group.if_cond)
        if attrs.has_key?("if")
          vue_warn(%(#{child.path}: if= on a child of a gated) \
                   %( <template> — a combined condition is not in the) \
                   %( subset; the child's own if= wins))
        else
          attrs["if"] = cond
        end
      end
      if (cond = group.unless_cond)
        if attrs.has_key?("unless")
          vue_warn(%(#{child.path}: unless= on a child of a gated) \
                   %( <template> — a combined condition is not in the) \
                   %( subset; the child's own unless= wins))
        else
          attrs["unless"] = cond
        end
      end
      Node.new(child.kind, child.name, attrs, child.children, child.path)
    end

    # `item in items` / `(item, i) in items` — bare names only.
    V_FOR_RE = /\A(?:\(\s*([a-zA-Z_]\w*)\s*,\s*([a-zA-Z_]\w*)\s*\)|([a-zA-Z_]\w*))\s+in\s+([a-zA-Z_]\w*)\z/

    # `<row v-for="doc in docs" :key="doc.name">…</row>` →
    # `<repeat for="doc" in="docs" key="name"><row>…</row></repeat>`.
    # The wrapper takes the original node's path (widget ids of a
    # document BORN in v-for syntax are stable; rewriting an existing
    # canonical document shifts paths one level — a documented caveat,
    # not a migration). The `(item, i)` spelling exposes the row index
    # as `{i}` next to `{_i}` (the `index=` wrapper attr).
    #
    # `<template v-for>` — the Vue list pattern: the GROUP repeats,
    # so EVERY template child rides the wrapper (each keeping its own
    # parsed path, already namespaced under the template). Other
    # template attrs are group-level only and drop with the wrapper.
    private def self.wrap_v_for(node : Node) : Node
      spec = node.attrs["v-for"].not_nil!
      unless m = spec.match(V_FOR_RE)
        vue_warn(%(#{node.path}: v-for="#{spec}" — expected `item in) \
                 %( list` or `(item, i) in list`))
        return rebuild_without(node, "v-for")
      end
      if node.kind.use? || node.kind.partial?
        vue_warn(%(#{node.path}: v-for on <#{node.name}> is not) \
                 %( supported — wrap a <repeat> manually))
        return rebuild_without(node, "v-for")
      end

      wrap_attrs = {"for" => (m[1]? || m[3]? || "item"),
                    "in" => (m[4]? || "")} of String => String
      if (key = node.attrs["key"]?)
        wrap_attrs["key"] = key
      end
      if (index_alias = m[2]?)
        wrap_attrs["index"] = index_alias
      end

      if node.kind.template?
        children = node.children.map { |c| copy_group_gate(node, c) }
        Node.new(Kind::Repeat, "repeat", wrap_attrs, children, node.path)
      else
        child_attrs = node.attrs.dup
        child_attrs.delete("v-for")
        child_attrs.delete("key")
        child = Node.new(node.kind, node.name, child_attrs, node.children,
          "#{node.path}/#{node.name}[0]")
        Node.new(Kind::Repeat, "repeat", wrap_attrs, [child], node.path)
      end
    end

    private def self.rebuild_without(node : Node, attr : String) : Node
      attrs = node.attrs.dup
      attrs.delete(attr)
      Node.new(node.kind, node.name, attrs, node.children, node.path)
    end

    private def self.unescape(s : String) : String
      s.gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", "\"")
        .gsub("&apos;", "'").gsub("&amp;", "&")
    end

    # The tag loop shared by `parse` and `parse_fragment`: returns the
    # top-level nodes. Virtual root tuple: {tag, attrs, children-sink,
    # path-prefix}; never popped empty. The prefix accumulates from the
    # root so every node's path is GLOBALLY unique — two buttons in two
    # rows must never share an egui Id (DuplicateWidgetIdError).
    #
    # The scan is BYTE-based on purpose: String's char-indexed API
    # (char_at/index/[]) hides an O(position) walk per call on
    # multibyte strings — with any non-ASCII text (Russian labels)
    # this loop went quadratic and a 27 KB document parsed in
    # ~200 ms release / ~1.4 s dev. UTF-8 can never collide with the
    # delimiters: multibyte sequences are bytes >= 0x80, '<'/'>'/'"'
    # are ASCII.
    def self.parse_tags(text : String) : Array(Node)
      warnings.clear
      # strip comments and processing instructions up front
      text = text.gsub(/<!--.*?-->/m, "").gsub(/<\?.*?\?>/m, "")

      bytes = text.to_unsafe
      bytesize = text.bytesize

      root_children = [] of Node
      stack = [{ "", {} of String => String, root_children, "" }] of
        {String, Hash(String, String), Array(Node), String}

      pos = 0
      while pos < bytesize
        lt = index_byte(bytes, bytesize, 0x3C_u8, pos) || break
        gt = index_tag_end(bytes, bytesize, lt)
        unless gt
          STDERR.puts "exml: unterminated tag at byte #{lt} — rest skipped"
          break
        end
        attach_text_segment(stack, text, pos, lt)
        inner = text.byte_slice(lt + 1, gt - lt - 1)
        pos = gt + 1
        next if inner.empty?

        if inner.starts_with?('/')
          name = inner[1..].strip.downcase
          if stack.size == 1
            STDERR.puts "exml: closing </#{name}> without an open element"
          else
            STDERR.puts "exml: </#{name}> closes <#{stack.last[0]}> — tolerated" \
              if stack.last[0] != name
            open = stack.pop
            attach(stack, open)
          end
        else
          self_close = inner.ends_with?('/')
          inner = inner.rchop if self_close
          name, attrs = parse_tag(inner)
          next unless name
          # The child's path: parent prefix + this element's position
          # (children attach at close, so the sink's size IS this
          # child's index) + an explicit id tag when present (`ref=`
          # too — it renames to id= in the desugar right below).
          parent = stack.last
          id_tag = attrs.not_nil!["id"]? || attrs.not_nil!["ref"]?
          path = "#{parent[3]}/#{name}[#{parent[2].size}]" \
                 "#{id_tag ? ":#{id_tag}" : ""}"
          desugar_vue_attrs(attrs.not_nil!, path) if vue_attrs?(attrs.not_nil!)
          if self_close
            attach(stack, {name, attrs.not_nil!, [] of Node, path})
          else
            stack << {name, attrs.not_nil!, [] of Node, path}
          end
        end
      end

      attach_text_segment(stack, text, pos, bytesize)
      unless stack.size == 1
        STDERR.puts "exml: unclosed <#{stack.last[0]}> at EOF — dropped"
      end
      desugar_vue_tree(root_children)
      root_children
    end

    # Bare text between tags becomes a `#text` node (Kind::Label, the
    # text in the "text" attr) attached to the innermost open element —
    # HTML fragments (`<p>hello <strong>bold</strong></p>`) carry their
    # prose this way, and a custom handler reads it as inline content.
    # Whitespace-only segments are dropped: markup files keep their
    # pretty-printing without junk label nodes.
    private def self.attach_text_segment(stack, text : String,
                                         from : Int32, to : Int32) : Nil
      seg = text.byte_slice(from, to - from)
      return if seg.each_byte.all? { |b| b.in?(0x20_u8, 0x09_u8, 0x0A_u8, 0x0D_u8) }
      parent = stack.last
      parent[2] << Node.new(Kind::Label, "#text",
        {"text" => unescape(seg)}, [] of Node,
        "#{parent[3]}/#text[#{parent[2].size}]")
    end

    # First occurrence of `needle` at or after `from` (nil = absent) —
    # a plain byte scan so the tag loop stays linear in file size.
    private def self.index_byte(bytes : UInt8*, bytesize : Int32,
                                needle : UInt8, from : Int32) : Int32?
      i = from
      while i < bytesize
        return i if bytes[i] == needle
        i += 1
      end
      nil
    end

    # The '>' closing a tag, skipping quoted attribute values — an
    # attribute may legally hold '>' (`v-if="count > 0"`, text="a > b")
    # and the naive first-'>' scan split the tag there, cascading junk
    # warnings and a broken tree. nil = unterminated. Byte-based like
    # the rest of the scan (see parse_tags).
    private def self.index_tag_end(bytes : UInt8*, bytesize : Int32,
                                   lt : Int32) : Int32?
      in_quote = false
      i = lt + 1
      while i < bytesize
        c = bytes[i]
        if in_quote
          in_quote = false if c == 0x22_u8 # '"'
        elsif c == 0x22_u8
          in_quote = true
        elsif c == 0x3E_u8 # '>'
          return i
        end
        i += 1
      end
      nil
    end

    # A fragment: top-level WIDGETS, no page/modal wrapper — what a
    # Component's `template` is. No partial expansion (partials belong
    # to a Document; a component template is self-contained).
    def self.parse_fragment(text : String) : Array(Node)
      parse_tags(text)
    end

    # Turn a popped open-tag tuple into a Node attached to the parent.
    # Unknown names become Kind::Custom WITHOUT a warning — the app may
    # well have a handler registered (Renderer#on); the warn-once moves
    # to render time, where a handler is actually missing.
    private def self.attach(stack, open)
      name, attrs, children, path = open
      kind = KIND_BY_NAME[name]? || Kind::Custom
      stack.last[2] << Node.new(kind, name, attrs, children, path)
    end

    # ── document ───────────────────────────────────────────────────────

    # The parsed top-level pages plus the file it all came from.
    # `#reload_if_changed` stats that file (mtime) and re-parses on an
    # external edit — hot reload, the ECSS session pattern.
    class Document
      getter pages : Array(Node)
      getter partials : Hash(String, Node)
      getter path : String?
      # Bumps on every hot-reload (#reload_if_changed) — the subtree-key
      # memoization folds it, so re-parsed markup can never be served
      # from a stale memo (paths repeat across reloads).
      getter version : UInt64 = 0u64
      @mtime : Time? = nil

      def initialize(@pages, @partials = {} of String => Node,
                     @path : String? = nil)
        @mtime = stat_mtime
      end

      def self.parse(text : String) : Document
        Exml.parse(text)
      end

      def self.load(path : String) : Document
        text = File.read(path)
        doc = Exml.parse(text)
        doc.path = path
        doc
      rescue e : IO::Error | File::Error
        STDERR.puts "exml: cannot read #{path}: #{e.message}"
        Document.new([] of Node, path: path)
      end

      # The hybrid front-end (plans/NativeHTML.md §6): one renderer,
      # three declaration sources —
      #   1. the live file at `path` when it exists (dev: hot-reload
      #      through #reload_if_changed);
      #   2. the generated literals (`generated` — the module egui-gen
      #      emits; release: no XML parse at first frame);
      #   3. neither (standalone): #load reports the missing file and
      #      yields the empty document.
      def self.hybrid(path : String,
                      generated : (-> Document)? = nil) : Document
        return load(path) if File.file?(path)
        if (gen = generated.try(&.call))
          return gen
        end
        load(path)
      end

      # True when the file was re-parsed (its mtime moved). Missing
      # files just report false — the pages stay as parsed.
      def reload_if_changed : Bool
        return false unless path = @path
        mtime = stat_mtime
        return false unless mtime && mtime != @mtime
        fresh = Document.load(path)
        return false if fresh.pages.empty?
        @pages = fresh.pages
        @partials = fresh.partials
        @mtime = mtime
        @version &+= 1u64
        true
      end

      def page(id : String) : Node?
        @pages.find { |p| p.attrs["id"]? == id }
      end

      protected def path=(path : String)
        @path = path
        @mtime = stat_mtime
      end

      private def stat_mtime : Time?
        return nil unless p = @path
        File.info(p).modification_time
      rescue File::Error | IO::Error
        nil
      end
    end

    # ── components ─────────────────────────────────────────────────────
    #
    # A component: template markup + the Crystal logic behind it, one
    # class per component — the Vue SFC shape with the script half in
    # COMPILED Crystal instead of interpreted JS (no VM needed: the
    # class is built by the normal compiler pass).
    #
    #   class Counter < Egui::Exml::Component
    #     exml "assets/components/counter.exml"  # or override #template
    #
    #     def setup(rt)        # once: seed slots, register actions
    #       rt.floats["count"] = 0
    #       rt.actions["inc"] = ->bump
    #     end
    #
    #     def bump : Nil       # the @click="count++" half, in Crystal
    #       rt.not_nil!.floats["count"] += 1
    #     end
    #   end
    #
    #   renderer.component(Counter.new) → `<counter/>` in any markup.
    #
    # The `exml "path"` macro embeds the template at compile time (the
    # binary runs standalone) but prefers the live file at runtime —
    # template edits hot-reload like any Document. `#update(ctx, rt)`
    # runs every frame before the template renders (computed/live
    # values).
    #
    # LOCAL STATE: every use site gets its own ScopedRuntime — reads
    # fall back to the app's global store (model slots stay reachable),
    # writes and action registrations land locally. A component's slots
    # never collide with the app's or another component's, and two
    # `<counter/>` sites keep independent state. `#rt` (and the rt the
    # hooks receive) IS the site's scope.
    class Component
      getter rt : Runtime? = nil
      @nodes : Array(Node)? = nil
      @mtime : Time? = nil
      @scopes = {} of String => ScopedRuntime
      # Use-site paths → the template children re-pathed under them
      # (memoized — the walk re-renders sites every frame and repathing
      # per frame allocated a fresh subtree per site per frame).
      @repathed = {} of String => Array(Node)

      # Template source; the `exml` macro overrides both this and
      # `#template_path` (kept for the hot-reload stat).
      getter template_path : String? = nil

      def template : String
        ""
      end

      macro exml(path)
        def template_path : String?
          {{path}}
        end

        # Live file first (hot reload), the compile-time copy as the
        # fallback for a standalone binary.
        def template : String
          File.read({{path}})
        rescue File::Error | IO::Error
          {{read_file(path)}}
        end
      end

      # Element name in markup: the demodulized, underscored class name
      # (Counter → "counter", FpsMeter → "fps_meter"). Override for a
      # custom one.
      def element_name : String
        self.class.name.split("::").last.underscore
      end

      # Once per use site: seed the local store, register the
      # component's actions (into the site's scope).
      def setup(rt : Runtime) : Nil
      end

      # Every frame, before the template renders: publish computed and
      # live values into the store.
      def update(ctx : Context, rt : Runtime) : Nil
      end

      # Internal: per-site scope (install-once + per-frame update) +
      # the template walk, nodes re-pathed under the USE site (two
      # `<counter/>` sites keep independent widget ids AND independent
      # store scopes).
      def render_with(node : Node, ui : Ui, ctx : Context, rt : Runtime,
                      renderer : Renderer) : Nil
        scope = @scopes[node.path]? || begin
          fresh = ScopedRuntime.new(rt)
          seed_props(node, fresh, rt) # readable by setup on install
          @scopes[node.path] = fresh
          @rt = fresh
          setup(fresh)
          fresh
        end
        # Props are LIVE (Vue semantics): re-seeded from the use site
        # every frame, a dynamic one (`label="{status}"`) following
        # the enclosing store. Prop keys belong to the use site — a
        # write from setup/update is overwritten next frame.
        seed_props(node, scope, rt)
        update(ctx, scope)
        (@repathed[node.path] ||= nodes.map { |c| Exml.repath(c, node.path) })
          .each { |child| renderer.render(child, ui, ctx, scope) }
      end

      # The use-site attributes seed the scope — Vue's
      # `<Counter :start="5"/>`. Values interpolate against the
      # ENCLOSING store (so `label="{selected}"` is dynamic);
      # structural attrs (if/unless/id) are not props.
      # structural attrs (if/unless/id) are not props, and neither are
      # the hotkey pair (window-global, not a per-widget value)
      private def seed_props(node : Node, scope : ScopedRuntime,
                             rt : Runtime) : Nil
        node.attrs.each do |k, v|
          next if {"if", "unless", "id", "hotkey", "on_keyup",
                   "on_keydown"}.includes?(k)
          scope.strings[k] = rt.interpolate(v)
        end
      end

      # The parsed template, hot-reloading when `exml "path"` supplied
      # one and the live file's mtime moved.
      def nodes : Array(Node)
        if (path = template_path) &&
           (mtime = file_mtime(path)) && mtime != @mtime
          begin
            fresh = Exml.parse_fragment(File.read(path))
            unless fresh.empty?
              @nodes = fresh
              @repathed.clear # site subtrees embed the OLD tree
              @mtime = mtime
            end
          rescue File::Error | IO::Error
          end
        end
        @nodes ||= begin
          @mtime = template_path.try { |p| file_mtime(p) }
          Exml.parse_fragment(template)
        end
      end

      private def file_mtime(path : String) : Time?
        File.info(path).modification_time
      rescue File::Error | IO::Error
        nil
      end
    end

    # ── linter ─────────────────────────────────────────────────────────
    #
    # Build-time vocabulary check: every element against its allowed
    # attribute names, required attributes and value shapes — so a
    # markup/enum drift (a typo'd attr, a widget that lost a param)
    # surfaces at build/test time (the spec suite lints assets/*.exml)
    # instead of a silently misrendering widget. `known_custom` lists
    # the custom elements the app registers handlers for — an unknown
    # one is itself an issue.

    # Structural attrs every element accepts; the hotkey pair rides
    # here too — the binding is window-global, not a per-widget prop.
    COMMON_ATTRS = %w(if unless id hotkey on_keyup on_keydown)

    ATTRS_BY_KIND = {
      Kind::Page      => %w(title),
      Kind::Modal     => %w(title buttons delimiter on_button),
      Kind::MenuBar   => %w(),
      Kind::Menu      => %w(label),
      Kind::MenuItem  => %w(label on_click hint),
      Kind::Central   => %w(),
      Kind::Statusbar => %w(),
      Kind::Row       => %w(),
      Kind::Column    => %w(),
      Kind::Box       => %w(direction wrap border fill padding rounding class flex justify align gap width height
                             position top right bottom left z),
      Kind::Heading   => %w(text),
      Kind::Label     => %w(text live),
      Kind::Button    => %w(text on_click type),
      Kind::Slider    => %w(bind min max on_change),
      Kind::Checkbox  => %w(bind text on_change),
      Kind::Separator => %w(),
      Kind::Progress  => %w(bind text),
      Kind::Input     => %w(bind hint focus_id on_change numeric trim required pattern),
      Kind::Textarea  => %w(bind hint rows frame editor_id on_change),
      Kind::Combo     => %w(bind options delimiter on_change),
      Kind::Toggle    => %w(bind text on_change),
      Kind::Form      => %w(),
      Kind::OpenFile  => %w(bind text text_choosing text_done filters title directory
                             multiple class label_class on_change),
      Kind::SaveFile  => %w(bind text text_choosing text_done filters title directory
                             default_name class label_class on_change),
      Kind::Custom    => %w(), # handler-defined — not checked
      Kind::Partial   => %w(),
      Kind::Use       => %w(partial),
      Kind::Repeat    => %w(for in key index),
      Kind::Markdown  => %w(text base_dir),
      Kind::FlexItem  => %w(grow shrink basis order align),
      Kind::Template  => %w(), # parse-time only — spliced away
      Kind::WindowFrame => %w(style title),
      Kind::WindowFrameCustom => %w(style title height),
      Kind::WindowButton => %w(type on_click),
    } of Kind => Array(String)

    REQUIRED_BY_KIND = {
      Kind::Page => "id", Kind::Modal => "id",
      Kind::Menu => "label", Kind::MenuItem => "label",
      Kind::Heading => "text", Kind::Label => "text",
      Kind::Button => "text", Kind::Slider => "bind",
      Kind::Checkbox => "bind", Kind::Progress => "bind",
      Kind::Input => "bind", Kind::Textarea => "bind",
      Kind::Combo => "bind", Kind::Use => "partial",
      Kind::OpenFile => "bind", Kind::SaveFile => "bind",
      Kind::Repeat => "in", Kind::Markdown => "text",
      Kind::WindowButton => "type",
    } of Kind => String

    # Returns the list of issues (empty = clean). Each line carries the
    # node's document path for a click-to-jump feel in editor output.
    # The global `widget` registry counts as registered custom
    # elements — the linter mirrors what the dispatcher does
    # (instance `#on` first, then the registry).
    def self.validate(doc : Document,
                      known_custom : Iterable(String) = [] of String) : Array(String)
      known = known_custom.to_a + widgets.keys
      issues = [] of String
      seen_pages = Set(String).new
      doc.pages.each do |page|
        if (pid = page.attrs["id"]?) && !seen_pages.add?(pid)
          issues << "#{page.path}: duplicate page id \"#{pid}\""
        end
        validate_node(page, known, issues)
      end
      issues
    end

    def self.validate_node(node : Node, known_custom : Enumerable(String),
                           issues : Array(String)) : Nil
      # A handler-claimed name is custom vocabulary — including a
      # built-in name overridden via `#on`/`widget` (the dispatcher
      # gives custom handlers priority over builtins; the linter
      # mirrors it): the handler owns the attrs, nothing builtin
      # to check.
      return if known_custom.includes?(node.name)

      case node.kind
      when .custom?
        issues << "#{node.path}: <#{node.name}> — no handler registered" \
                  " for this app's renderer"
        return
      when .partial?, .use?, .template?
        issues << "#{node.path}: <#{node.name}> leaked into the tree" \
                  " (parse-time element)"
        return
      end

      if allowed = ATTRS_BY_KIND[node.kind]?
        node.attrs.each_key do |attr|
          next if COMMON_ATTRS.includes?(attr)
          unless allowed.includes?(attr)
            issues << "#{node.path}: <#{node.name}> has no attribute" \
                      " \"#{attr}\" — typo or drifted vocabulary?"
          end
        end
        if (req = REQUIRED_BY_KIND[node.kind]?) && !node.attrs[req]?
          issues << "#{node.path}: <#{node.name}> requires \"#{req}\""
        end
      end

      case node.kind
      when .slider?
        %w(min max).each do |a|
          if (v = node.attrs[a]?) && v.to_f?.nil?
            issues << "#{node.path}: #{a}=#{v.inspect} is not a number"
          end
        end
      when .textarea?
        if (v = node.attrs["rows"]?) && v.to_i?.nil?
          issues << "#{node.path}: rows=#{v.inspect} is not an integer"
        end
        if (v = node.attrs["frame"]?) && !%w(true false).includes?(v)
          issues << "#{node.path}: frame=#{v.inspect} must be true/false"
        end
      when .label?
        if (v = node.attrs["live"]?) && !%w(true false).includes?(v)
          issues << "#{node.path}: live=#{v.inspect} must be true/false"
        end
      when .input?
        %w(numeric trim).each do |a|
          if (v = node.attrs[a]?) && !%w(true false).includes?(v)
            issues << "#{node.path}: #{a}=#{v.inspect} must be true/false"
          end
        end
      when .box?
        if (v = node.attrs["direction"]?) &&
           !%w(row column row-reverse column-reverse).includes?(v)
          issues << "#{node.path}: direction=#{v.inspect} must be" \
                    " row/column/row-reverse/column-reverse"
        end
        if (v = node.attrs["wrap"]?) &&
           !%w(true false wrap nowrap wrap-reverse).includes?(v)
          issues << "#{node.path}: wrap=#{v.inspect} must be" \
                    " true/false/wrap/nowrap/wrap-reverse"
        end
        if (v = node.attrs["flex"]?) && !%w(true false).includes?(v)
          issues << "#{node.path}: flex=#{v.inspect} must be true/false"
        end
        %w(gap padding rounding).each do |a|
          if (v = node.attrs[a]?) && v.to_f?.nil?
            issues << "#{node.path}: #{a}=#{v.inspect} is not a number"
          end
        end
        %w(fill border).each do |a|
          # `{placeholder}` fill/border is store-interpolated at render
          # time (see the Box render path) — validated then, not here
          next if (v = node.attrs[a]?) && v.includes?('{')
          if (v = node.attrs[a]?) && Exml.parse_box_color(v).nil?
            issues << "#{node.path}: #{a}=#{v.inspect} is not a #rrggbb color"
          end
        end
        if (v = node.attrs["position"]?) &&
           !%w(absolute relative fixed).includes?(v)
          issues << "#{node.path}: position=#{v.inspect} must be" \
                    " absolute/relative/fixed"
        end
      when .flex_item?
        %w(grow shrink).each do |a|
          if (v = node.attrs[a]?) && v.to_f?.nil?
            issues << "#{node.path}: #{a}=#{v.inspect} is not a number"
          end
        end
        if (v = node.attrs["order"]?) && v.to_i?.nil?
          issues << "#{node.path}: order=#{v.inspect} is not an integer"
        end
      when .window_frame?
        unless node.children.empty?
          issues << "#{node.path}: <window-frame> takes no children — " \
                    "use <window-frame-custom> for explicit buttons/content"
        end
        issue_frame_style(node, issues)
      when .window_frame_custom?
        issue_frame_style(node, issues)
        if (v = node.attrs["height"]?) && v.to_f?.nil?
          issues << "#{node.path}: height=#{v.inspect} is not a number"
        end
      when .window_button?
        if (v = node.attrs["type"]?) &&
           !%w(minimize maximize close).includes?(v)
          issues << "#{node.path}: type=#{v.inspect} must be" \
                    " minimize/maximize/close"
        end
      end

      node.children.each { |c| validate_node(c, known_custom, issues) }
    end

    # `style=` on a frame element: a WindowFrame::STYLE_NAMES key (a
    # `{placeholder}` value is store-interpolated at render time and
    # skipped here, like a dynamic box fill).
    private def self.issue_frame_style(node : Node, issues : Array(String))
      if (v = node.attrs["style"]?) && !v.includes?('{') &&
         !WindowFrame::STYLE_NAMES.has_key?(v)
        issues << "#{node.path}: style=#{v.inspect} must be one of " \
                  "#{WindowFrame::STYLE_NAMES.keys.join(", ")}"
      end
    end

    # ── runtime ────────────────────────────────────────────────────────

    # The store the markup binds to: named string/float/bool slots the
    # app writes (its model) and the widgets write back (bindings), plus
    # the named actions markup can fire. All logic stays in the binary —
    # actions are registered procs, never markup.
    # Версионированное хранилище слота (push-дифф §8,
    # FPS_OPTIMIZATION.md): запись с ИЗМЕНЁННЫМ значением поднимает
    # версию имени. Мемоизация ключей subtree (Renderer#
    # custom_subtree_key) сравнивает версии вместо реинтерполяции
    # всех атрибутов поддерева — стационарный кадр не платит за
    # value-дифф. Наследник Hash: все читатели ([]=, []?, each,
    # merge!) работают как раньше; == контентный, спеки не видят
    # подкласс. `always` — для rows: значение — Array, который
    # приложение может мутировать на месте (контракт «renderer only
    # reads»), глубокое сравнение стоило бы строк на каждую запись —
    # версия поднимается на каждую запись.
    class SlotHash(K, V) < Hash(K, V)
      def initialize(@versions : Hash(K, UInt64), @always : Bool = false)
        super()
      end

      def []=(key : K, value : V) : V
        if @always || (old = self[key]?).nil? || old != value
          @versions[key] = (@versions[key]? || 0u64) &+ 1
        end
        super(key, value)
      end

      def delete(key : K) : V?
        @versions[key] = (@versions[key]? || 0u64) &+ 1
        super(key)
      end
    end

    class Runtime
      @slot_versions = {} of String => UInt64

      # Версия слота-имени: 0 = никогда не писался. Компонентный
      # скоуп смешивает свою и родительскую (мультипликативно — обе
      # стороны видны). Читается мемоизацией ключей каждый кадр.
      def slot_version(name : String) : UInt64
        @slot_versions[name]? || 0u64
      end

      property strings : SlotHash(String, String)
      property floats : SlotHash(String, Float64)
      property bools : SlotHash(String, Bool)
      property actions = {} of String => -> Nil
      # List slots — the `<repeat over="…">` data: rows of string
      # fields the app publishes (one nesting level; format numbers
      # on the app side, like every other slot). Combo `<combo
      # :options="…">` uses the same push model with a plain
      # Array(String): the app owns the array's lifetime (may mutate
      # it in place), the renderer only reads — a steady-state frame
      # allocates nothing.
      property rows : SlotHash(String, Array(Hash(String, String)))
      property lists = {} of String => Array(String)

      def initialize
        @strings = SlotHash(String, String).new(@slot_versions)
        @floats = SlotHash(String, Float64).new(@slot_versions)
        @bools = SlotHash(String, Bool).new(@slot_versions)
        @rows = SlotHash(String, Array(Hash(String, String))).new(
          @slot_versions, always: true)
      end

      # The rows of a list slot; nil = no such slot (a warn-once at
      # render time, not here — lenient).
      def rows?(key : String) : Array(Hash(String, String))?
        rows[key]?
      end

      # The options of a bound combo (`:options=`); nil = no such
      # slot — the same lenient warn-once at render time.
      def list?(key : String) : Array(String)?
        lists[key]?
      end

      # One key's display string — strings verbatim, floats with two
      # decimals, bools as true/false; nil = no such slot. The
      # interpolation hook: ScopedRuntime overrides this for the
      # local-then-parent fallback.
      def lookup(key : String) : String?
        if v = strings[key]?
          v
        elsif f = floats[key]?
          "%.2f" % f
        elsif b = bools[key]?
          b.to_s
        end
      end

      # "{name}" substitution from the store (dotted keys allowed —
      # the `<repeat>` scopes flatten row fields into "item.field").
      # Unknown names survive as-is (a spot of `{oops}` in the UI says
      # more than a crash).
      #
      # Results are CACHED per raw text: the slot values a text reads
      # are compared on every call, so a frame in which nothing moved
      # returns the previous String with zero allocation — dynamic
      # labels were the walk's main allocator. A changed value just
      # rebuilds and re-caches (compare-on-read, nothing to evict).
      @interp_cache = {} of String => Tuple(Array(String), Array(String), String)

      # Row scopes (repeat) live ONE frame — a cache there never hits
      # and only adds its bookkeeping allocations; they interpolate
      # uncached. Overridden by ScopedRuntime.
      def cache_interpolations? : Bool
        true
      end

      def interpolate(text : String) : String
        return text unless text.includes?('{')
        return interpolate_uncached(text) unless cache_interpolations?
        if cached = @interp_cache[text]?
          names, values, result = cached
          changed = false
          names.each_with_index do |name, i|
            v = lookup(name) || "{#{name}}"
            if v != values[i]
              values[i] = v
              changed = true
            end
          end
          return result unless changed
          # placeholders are visited left-to-right by the same regex —
          # the values array is positional in that order
          i = 0
          result = text.gsub(/\{([a-zA-Z_][\w.]*)\}/) do
            v = values[i]
            i += 1
            v
          end
          @interp_cache[text] = {names, values, result}
          result
        else
          names = [] of String
          values = [] of String
          result = interpolate_collect(text, names, values)
          @interp_cache[text] = {names, values, result}
          result
        end
      end

      # Plain "{name}" substitution, no cache bookkeeping — the
      # row-scope path (a repeat scope dies with its frame).
      private def interpolate_uncached(text : String) : String
        text.gsub(/\{([a-zA-Z_][\w.]*)\}/) do
          lookup($1) || "{#{$1}}"
        end
      end

      # gsub collecting the placeholder names and resolved values on
      # the way (the cache's positional bookkeeping).
      private def interpolate_collect(text : String, names : Array(String),
                                      values : Array(String)) : String
        text.gsub(/\{([a-zA-Z_][\w.]*)\}/) do
          names << $1
          v = lookup($1) || "{#{$1}}"
          values << v
          v
        end
      end

      def bool(key : String) : Bool
        bools[key]? || false
      end

      def string(key : String) : String
        strings[key]? || ""
      end

      def float(key : String, default : Float64 = 0.0) : Float64
        floats[key]? || default
      end

      def fire(name : String) : Nil
        if act = actions[name]?
          act.call
        else
          STDERR.puts "exml: no action registered for \"#{name}\""
        end
      end
    end

    # A component's local store: reads fall back to the parent (the
    # app's global Runtime — model slots stay reachable), writes and
    # action registrations land LOCALLY — so a component's slots and
    # actions never collide with the app's or another component's,
    # and two use sites of one component keep independent state (the
    # scope lives per use-site path, see Component#render_with).
    class ScopedRuntime < Runtime
      def initialize(@parent : Runtime)
        super()
      end

      # The `<repeat>` row this scope renders (nil outside a repeat):
      # firing an action writes the row INDEX to the root store as
      # "_i" first — the `_modal_button` pattern generalized, so a
      # list action knows which row fired (app reads rt.string("_i")).
      property repeat_index : Int32? = nil

      # A row scope lives one frame — an interpolation cache there
      # never hits, it only allocates the bookkeeping. Rows render
      # uncached; long-lived scopes (components) keep the cache.
      def cache_interpolations? : Bool
        repeat_index.nil?
      end

      # Slot versions mix both stores: a name may resolve locally or
      # fall through to the parent, so a bump on EITHER side must
      # re-key (multiplicative mix — both directions visible).
      def slot_version(name : String) : UInt64
        super(name) &* 1_000_003u64 &+ @parent.slot_version(name)
      end

      def lookup(key : String) : String?
        super || @parent.lookup(key)
      end

      def rows?(key : String) : Array(Hash(String, String))?
        super || @parent.rows?(key)
      end

      def list?(key : String) : Array(String)?
        super || @parent.list?(key)
      end

      def bool(key : String) : Bool
        v = bools[key]?
        return v unless v.nil?
        @parent.bool(key)
      end

      def string(key : String) : String
        strings[key]? || @parent.string(key)
      end

      def float(key : String, default : Float64 = 0.0) : Float64
        v = floats[key]?
        return v if v
        @parent.float(key, default)
      end

      def fire(name : String) : Nil
        if (i = @repeat_index)
          root.strings["_i"] = i.to_s
        end
        if act = actions[name]?
          act.call
        else
          @parent.fire(name)
        end
      end

      # The outermost Runtime (the app's global store) — where
      # per-row context like "_i" lands.
      def root : Runtime
        p = @parent
        p.is_a?(ScopedRuntime) ? p.root : p
      end
    end

    # ── renderer ───────────────────────────────────────────────────────

    # Walks the tree every frame, dispatching to the regular egui.cr
    # widgets. One Renderer instance should live across frames: it
    # remembers the last editor child-Ui id to drive focus-follows-tab.
    class Renderer
      @last_editor_id : String? = nil

      # Custom element handlers: name → render proc. Registered per
      # application with `#on` — the extension point that keeps the
      # built-in vocabulary closed but the total one open. The handler
      # receives everything: the node (attrs/children/path — resample
      # from the store through rt.interpolate itself), the ui/ctx to
      # render anything, and this renderer (`render_each` walks the
      # element's children — custom containers).
      alias CustomHandler = Node, Ui, Context, Runtime, Renderer ->

      @custom = {} of String => CustomHandler
      @warned_custom = Set(String).new
      # Retained-subtree bookkeeping (see #subtree_generation): the
      # per-path appearance generation, the paths rendered LAST frame
      # and the ones rendered so far THIS frame (rotated in
      # #render_routes — the per-frame entry point)
      @subtree_gens = {} of String => Int32
      @subtree_last = Set(String).new
      @subtree_cur = Set(String).new
      # Hotkeys markup bound LAST frame (`hotkey=` from `@keyup.enter`
      # and friends): lapsed at every #render_routes — only the keys
      # of nodes visible THIS frame re-bind during the walk, so a
      # hidden node frees its key (Vue unmounts the listener).
      @markup_hotkeys = Set(Hotkey).new
      # Template refs: this frame's named widgets (`id="go"` in
      # markup) → their Response (rect, clicked?, hovered?, …) — the
      # app reads them after rendering via #ref. Cleared at every
      # #render_routes; a widget not rendered this frame leaves no
      # stale entry.
      @refs = {} of String => Response

      # The Response of the widget that carried `id="name"` in the
      # last rendered frame (nil = no such widget / not rendered).
      def ref(name : String) : Response?
        @refs[name]?
      end

      # Register a handler for a custom element name:
      #
      #   renderer.on("fps_meter") do |node, ui, ctx, rt, r|
      #     ctx.request_repaint
      #     ui.label("FPS: #{"%.1f" % ctx.fps}")
      #   end
      #
      # ...and `<fps_meter/>` in markup renders it. A name that IS a
      # builtin works too — the handler overrides the builtin (custom
      # dispatch runs before the built-in one), so any plain word can
      # be claimed. `if`/`unless` and visibility work like any
      # built-in element.
      def on(name : String, &handler : CustomHandler) : Nil
        @custom[name] = handler
      end

      # Register a Component: its class-derived element name becomes a
      # custom element whose handler seeds the store (`setup`), publishes
      # live values (`update`) and walks the component's template.
      #   renderer.component(Counter.new)
      def component(comp : Component) : Nil
        on(comp.element_name) do |node, ui, ctx, rt, r|
          comp.render_with(node, ui, ctx, rt, r)
        end
      end
      # Register every page/modal of the document with the router and
      # render the current route's tree (the router itself decides what
      # is on screen). `if`/`unless` on a page gate its registration —
      # a modal declared only while a confirmation is pending.
      def render_routes(ctx : Context, doc : Document, rt : Runtime) : Nil
        Egui::Bench.span("exml.render_routes") do
          render_routes_body(ctx, doc, rt)
        end
      end

      private def render_routes_body(ctx : Context, doc : Document,
                                     rt : Runtime) : Nil
        @refs.clear # refs describe the frame being rendered
        # rotate the presence sets: generations bump for nodes that
        # were absent last frame but are back now
        @subtree_last, @subtree_cur = @subtree_cur, @subtree_last
        @subtree_cur.clear
        # A hot-reloaded document invalidated every folded key and
        # every static name list — same paths may map to new markup.
        if doc.version != @doc_version
          @doc_version = doc.version
          @key_memo.clear
          @key_names.clear
        end
        # Last frame's markup hotkeys lapse; visible nodes re-bind
        # theirs during the walk (bind_hotkey below)
        @markup_hotkeys.each { |hk| ctx.hotkeys.unbind(hk) }
        @markup_hotkeys.clear
        ctx.routes do |r|
          doc.pages.each do |page|
            next unless visible?(page, rt)
            id = rt.interpolate(page.ref_name || "")
            if page.kind.modal?
              on_act = page.on_button
              on_button = ->(label : String) {
                rt.strings["_modal_button"] = label
                rt.fire(on_act.not_nil!) if on_act
              }
              r.modal(id, title: interp(page.title_attr, rt),
                buttons: page.buttons_list,
                on_button: on_act ? on_button : nil) do |ui|
                render_children(page, ui, ctx, rt)
              end
            else
              r.page(id, title: interp(page.title_attr, rt)) do |ui|
                render_children(page, ui, ctx, rt)
              end
            end
          end
        end
      end

      # Page body: layout sections (menubar/central/statusbar) go to
      # their ctx panels, everything else renders inline.
      private def render_children(page : Node, ui : Ui, ctx : Context,
                                  rt : Runtime) : Nil
        page.children.each do |child|
          case child.kind
          when .menu_bar?
            ctx.menu_bar { |bar| render_menu_bar(child, bar, ctx, rt) }
          when .central?
            ctx.central_panel(child.panel_id) do |panel|
              # Scrollable by default: a page's markup lists content
              # top-down and must stay reachable when the window runs
              # short — the ScrollArea reserves its strip up front and
              # shows the bar only when the content actually overflows
              # (inner scroll sinks — textareas — still take the wheel
              # first; see ScrollArea).
              panel.scroll_area do |scroll|
                render_children_of(child, scroll, ctx, rt)
              end
            end
          when .statusbar?
            ctx.bottom_panel(child.panel_id) do |panel|
              render_children_of(child, panel, ctx, rt)
            end
          else
            render(child, ui, ctx, rt)
          end
        end
      end

      private def render_children_of(node : Node, ui : Ui, ctx : Context,
                                     rt : Runtime) : Nil
        node.children.each { |c| render(c, ui, ctx, rt) }
      end

      # Public child walk for CUSTOM containers: a handler that claimed
      # a `<my_panel>` element lays out its own chrome, then walks the
      # element's children through the regular dispatch.
      def render_each(node : Node, ui : Ui, ctx : Context, rt : Runtime) : Nil
        node.children.each { |c| render(c, ui, ctx, rt) }
      end

      # ── dynamic `<box>` attributes ──────────────────────────────────
      # A `{placeholder}` value re-resolves from the store every frame
      # (dynamic fills — per-row cover gradients — and computed
      # extents/offsets); a static value keeps the parse-time field.

      private def box_attr_fill(node : Node, rt : Runtime) : Color32 | Gradient?
        raw = node.attrs["fill"]?
        if raw && raw.includes?('{')
          Exml.parse_box_color(rt.interpolate(raw)) || node.box_fill
        else
          node.box_fill
        end
      end

      private def box_attr_len(node : Node, rt : Runtime, key : String,
                               fallback : String?) : String?
        raw = node.attrs[key]?
        raw && raw.includes?('{') ? rt.interpolate(raw) : fallback
      end

      BOX_POSITIONS = {"absolute" => :absolute, "relative" => :relative,
                       "fixed" => :fixed} of String => Symbol

      # `position`/`top`/`right`/`bottom`/`left`/`z` — the CSS placement
      # vocabulary `Ui#box`/`Ui#flex` already speak (see #box_positioning).
      # Each offset is a px number, a StyleLength string ("50%") or a
      # `{placeholder}` — the values pass through as strings.
      private def box_positioning_attrs(node : Node, rt : Runtime)
        position = node.attrs["position"]?.try do |v|
          BOX_POSITIONS[rt.interpolate(v)]?
        end
        top = right = bottom = left : String? = nil
        if position || node.attrs["top"]? || node.attrs["right"]? ||
           node.attrs["bottom"]? || node.attrs["left"]?
          top = node.attrs["top"]?.try { |v| rt.interpolate(v) }
          right = node.attrs["right"]?.try { |v| rt.interpolate(v) }
          bottom = node.attrs["bottom"]?.try { |v| rt.interpolate(v) }
          left = node.attrs["left"]?.try { |v| rt.interpolate(v) }
        end
        z = node.attrs["z"]?.try { |v| rt.interpolate(v).to_i? }
        {position: position, top: top, right: right, bottom: bottom,
         left: left, z: z}
      end

      private def render_menu_bar(node : Node, bar : Ui, ctx : Context,
                                  rt : Runtime) : Nil
        node.children.each do |menu|
          next unless menu.kind.menu?
          bar.menu_button(rt.interpolate(menu.label_attr || "?")) do |m|
            menu.children.each do |item|
              next unless item.kind.menu_item?
              next unless visible?(item, rt)
              m.menu_item(rt.interpolate(item.label_attr || "?"),
                hotkey: item.hint_attr.try { |h| rt.interpolate(h) }) do
                fire_named(item.on_click, rt)
              end
            end
          end
        end
      end

      # The per-widget dispatch — the hot path (microseconds per page).
      # Below-clip culling — the incremental-layout layer. A node whose
      # cursor starts fully below the ambient clip is invisible; its
      # flow extent (dx, dy) and widget-id span, recorded the last time
      # it really rendered, replay in O(1) (Ui#cull_subtree). The
      # record refreshes on every real render, so scrolling it back
      # into view (or a structure change under the same path) rebuilds
      # it for real. Trade-offs, the same contract as a virtualized
      # row: markup hotkeys and refs of a culled subtree lapse for the
      # culled frames, and its Memory state (hover) may be pruned —
      # invisible widgets have none of that anyway.
      @culled = {} of String => Tuple(Float64, Float64, UInt64)

      def render(node : Node, ui : Ui, ctx : Context, rt : Runtime) : Nil
        unless ctx.measuring?
          if ui.cursor.y >= ui.clip.max.y
            if (rec = @culled[node.path]?)
              Egui::Bench.count("exml.cull.replay")
              ui.cull_subtree(rec[0], rec[1], rec[2])
              return
            end
            Egui::Bench.count("exml.cull.first")
          end
        end
        x0 = ui.cursor.x
        y0 = ui.cursor.y
        c0 = ui.child_counter
        render_body(node, ui, ctx, rt)
        dx = ui.cursor.x - x0
        dy = ui.cursor.y - y0
        @culled[node.path] = {dx, dy, ui.child_counter - c0} if dy > 0.0 || dx > 0.0
      end

      def render_body(node : Node, ui : Ui, ctx : Context, rt : Runtime) : Nil
        return unless visible?(node, rt)
        return unless style_visible?(node, ctx, rt)
        bind_hotkey(node, ui, ctx, rt)

        # Custom vocabulary has PRIORITY over builtins: a handler
        # registered for a name runs even when that name is a
        # built-in element (`on("label")` claims `<label>`). No
        # hyphen/naming convention is required to add an element.
        if (handler = custom_handler?(node))
          render_custom(node, ui, ctx, rt, handler)
          return
        end

        case node.kind
        in .menu_bar?
          # layout sections only render through render_children
          render_children(node, ui, ctx, rt)
        in .page?, .modal?, .central?, .statusbar?
          render_children(node, ui, ctx, rt)
        in .menu?
          # a bare menu outside a menubar renders as a plain column
          render_children_of(node, ui, ctx, rt)
        in .partial?, .use?, .template?
          # parse-time only: spliced away above; a leftover (a partial
          # defined mid-tree) renders nothing — the linter flags it
        in .repeat?
          render_repeat(node, ui, ctx, rt)
        in .row?
          ui.horizontal { |h| node.children.each { |c| render(c, h, ctx, rt) } }
        in .column?
          node.children.each { |c| render(c, ui, ctx, rt) }
        in .form?
          # `<form>` — the validation scope (form.cr): paints nothing,
          # lays out nothing (children flow like a column's); inputs
          # register against the pushed form id, and a
          # `type="submit"` button inside gates on them below.
          form_id = Id.from(node.path)
          ctx.push_form(form_id)
          begin
            node.children.each { |c| render(c, ui, ctx, rt) }
          ensure
            ctx.pop_form
          end
        in .box?
          margin = node.box_padding.try { |p| Vec2.new(p, p) }
          if node.box_flex
            # Flexbox container (Ui#flex): `direction`/`wrap`/`justify`/
            # `align`/`gap` are the CSS spellings, `width`/`height` the
            # definite extents a column flex needs. `<flex-item>`
            # children carry per-child grow/shrink/basis/order/align;
            # every other child is a plain flex item.
            wrap_sym = case (w = node.attrs["wrap"]?)
                       when "wrap", "true"            then :wrap
                       when "wrap-reverse"             then :wrap_reverse
                       else                                 :nowrap
                       end
            # `fill`/`width`/`height`/position offsets are store-
            # interpolatable: a `{placeholder}` value re-resolves every
            # frame (dynamic gradients from the data — e.g. per-row
            # covers), a static one keeps the parse-time cache.
            box_fill = box_attr_fill(node, rt)
            box_w = box_attr_len(node, rt, "width", node.box_width)
            box_h = box_attr_len(node, rt, "height", node.box_height)
            pos = box_positioning_attrs(node, rt)
            ui.flex(
              direction: Flex.parse_direction(node.attrs["direction"]?),
              wrap: wrap_sym,
              justify: Flex.parse_justify(node.box_justify),
              align: Flex.parse_cross_align(node.box_align),
              gap: node.box_gap.try { |g| Vec2.new(g, g) },
              fill: box_fill, stroke: node.box_stroke,
              # rounding only when EXPLICIT: an unpainted flex wrapper
              # with a rounding must not rounded-clip its subtree (an
              # SDF mask per flex container per frame — the ring
              # overflows on flex-heavy trees)
              rounding: node.attrs["rounding"]? ? node.box_rounding : 0.0,
              margin: margin,
              style_class: node.box_class,
              width: box_w, height: box_h,
              position: pos[:position], top: pos[:top],
              right: pos[:right], bottom: pos[:bottom],
              left: pos[:left], z: pos[:z]) do |f|
              node.children.each do |c|
                if c.kind.flex_item?
                  f.child(grow: c.flex_grow, shrink: c.flex_shrink,
                    basis: c.flex_basis || :auto, order: c.flex_order,
                    align_self: Flex.parse_cross_align(c.flex_align_self)) do |cell|
                    c.children.each { |cc| render(cc, cell, ctx, rt) }
                  end
                else
                  f.child { |cell| render(c, cell, ctx, rt) }
                end
              end
            end
          else
            pos = box_positioning_attrs(node, rt)
            ui.box(node.box_row ? :row : :column,
              wrap: node.box_wrap, fill: box_attr_fill(node, rt),
              stroke: node.box_stroke, rounding: node.box_rounding,
              margin: margin, style_class: node.box_class,
              position: pos[:position], top: pos[:top],
              right: pos[:right], bottom: pos[:bottom],
              left: pos[:left], z: pos[:z],
              width: box_attr_len(node, rt, "width", node.box_width),
              height: box_attr_len(node, rt, "height", node.box_height)) do |b|
              node.children.each { |c| render(c, b, ctx, rt) }
            end
          end
        in .flex_item?
          # Outside a flex box the wrapper is transparent — children
          # render into the plain flow (the linter flags the usage).
          node.children.each { |c| render(c, ui, ctx, rt) }
        in .heading?
          ref_set(node, ui.heading(text_of(node, rt)))
        in .label?
          ctx.request_repaint if node.live
          ref_set(node, ui.label(text_of(node, rt)))
        in .button?
          if ref_set(node, ui.button(text_of(node, rt, "?"), id: node.path)).clicked?
            # `type="submit"` inside a `<form>`: the click only fires
            # through a VALID form — a blocked attempt marks the form
            # attempted instead (fields reveal their `:invalid` state;
            # HTML submit semantics, minus the navigation). Outside a
            # form, or without the type, the button behaves as always.
            if node.button_type == "submit" &&
               (form_id = ctx.current_form_id)
              if ctx.form_inputs_invalid?(form_id)
                ctx.mark_form_attempted(form_id)
              else
                fire_named(node.on_click, rt)
              end
            else
              fire_named(node.on_click, rt)
            end
          end
        in .separator?
          ui.separator
        in .progress?
          frac = rt.float(node.bind_key || "")
          ref_set(node, ui.progress_bar(frac.clamp(0.0, 1.0),
            text: node.text_attr.try { |t| rt.interpolate(t) }))
        in .slider?
          key = node.bind_key || ""
          on_act = node.on_change
          ref_set(node, ui.slider(rt.float(key, node.slider_min),
            (node.slider_min..node.slider_max)) do |v|
            rt.floats[key] = v
            rt.fire(on_act.not_nil!) if on_act
          end)
        in .checkbox?
          key = node.bind_key || ""
          on_act = node.on_change
          ref_set(node, ui.checkbox(rt.bool(key),
            rt.interpolate(node.text_attr || ""), id: node.path) do |v|
            rt.bools[key] = v
            rt.fire(on_act.not_nil!) if on_act
          end)
        in .toggle?
          key = node.bind_key || ""
          on_act = node.on_change
          ref_set(node, ui.toggle_button(rt.bool(key),
            id: node.path) do |v|
            rt.bools[key] = v
            rt.fire(on_act.not_nil!) if on_act
          end)
        in .open_file?, .save_file?
          render_file_picker(node, ui, ctx, rt, save: node.kind.save_file?)
        in .input?
          key = node.bind_key || ""
          on_act = node.on_change
          # v-model.number (numeric="true"): the float slot — display
          # round-trips through Float#to_s, a half-typed "3." is not
          # clobbered (TextEdit owns its buffer); unparseable text
          # just doesn't write. trim strips the write-back.
          shown = node.numeric ? rt.float(key).to_s : rt.string(key)
          ref_set(node, ui.text_edit_singleline(shown,
            hint: node.hint_attr, focus_id: node.focus_id,
            required: node.input_required,
            pattern: node.input_pattern) do |t|
            t = t.strip if node.trim
            if node.numeric
              if (f = t.to_f?)
                rt.floats[key] = f
                rt.fire(on_act.not_nil!) if on_act
              end
            else
              rt.strings[key] = t
              rt.fire(on_act.not_nil!) if on_act
            end
          end)
        in .textarea?
          render_textarea(node, ui, ctx, rt)
        in .combo?
          key = node.bind_key || ""
          on_act = node.on_change
          # `:options="list"` (desugared to options="{list}") reads a
          # LIST slot the app publishes (rt.lists) — the dynamic
          # counterpart of the parse-time literal split. Missing slot:
          # warn-once and an empty list (the placeholder row).
          opts = node.combo_options
          if lkey = node.options_key
            if list = rt.list?(lkey)
              opts = list
            else
              unless @warned_custom.includes?("list:#{lkey}")
                @warned_custom << "list:#{lkey}"
                STDERR.puts "exml: options=\"{#{lkey}}\" — no such list" \
                            " slot; publish it as rt.lists[\"#{lkey}\"]"
              end
            end
          end
          ui.combo_box(node.path, rt.string(key), opts) do |opt|
            rt.strings[key] = opt
            rt.fire(on_act.not_nil!) if on_act
          end
        in .markdown?
          ref_set(node, ui.markdown(text_of(node, rt),
            base_dir: node.base_dir))
        in .window_frame?
          # The stock client-side chrome: one line, the style's default
          # caption (title + buttons). Draws its own top panel — the
          # node must come FIRST among the page's children so the
          # app's panels lay out below the caption.
          Egui::WindowFrame.show(ctx, interp(node.title_attr, rt) || "",
            frame_style_of(node, rt))
        in .window_frame_custom?
          render_window_frame_custom(node, ui, ctx, rt)
        in .window_button?
          # Only meaningful inside <window-frame-custom> (drawn by the
          # frame walk); reaching here means it sits elsewhere.
          unless @warned_custom.includes?("window_button")
            @warned_custom << "window_button"
            STDERR.puts "exml: <window-button> outside" \
                        " <window-frame-custom> — ignored"
          end
        in .custom?
          # No handler for this name (a registered one never reaches
          # the case — custom dispatch runs before it)
          unless @warned_custom.includes?(node.name)
            @warned_custom << node.name
            STDERR.puts "exml: no handler for <#{node.name}> — " \
                        "register one with Renderer#on; element skipped"
          end
        in .menu_item?
          # a bare item outside a menu renders as a button
          if ui.button(rt.interpolate(node.label_attr || "?"), id: node.path).clicked?
            fire_named(node.on_click, rt)
          end
        end
      end

      # The custom-element handler for this node: instance `#on`
      # first, then the global `widget` registry. Runs BEFORE the
      # built-in dispatch (#render_body), so a registered name wins
      # over its builtin — the linter mirrors this order.
      private def custom_handler?(node : Node) : CustomHandler?
        @custom[node.name]? || Exml.widgets[node.name]?
      end

      # Custom dispatch shared by every handler-claimed node: the
      # retained-subtree replay (a pure custom element replays its
      # whole span from the paint cache — layout, children and paint
      # skipped on a hit), else the plain handler call.
      private def render_custom(node : Node, ui : Ui, ctx : Context,
                                rt : Runtime,
                                handler : CustomHandler) : Nil
        if (skey = custom_subtree_key(node, ui, ctx, rt))
          # An appear run must survive end-frame pruning even on a
          # replay frame (the handler that drives it did not run):
          # a pruned run would make drive() start a fresh one and
          # re-play the entrance animation forever.
          if node.attrs["appear"]?
            ctx.memory.use_id(Egui::Id.from("#{node.path}/appear"))
          end
          ui.cached_subtree(skey) { handler.call(node, ui, ctx, rt, self) }
        else
          handler.call(node, ui, ctx, rt, self)
        end
      end

      # ── retained subtrees for custom elements ─────────────────────
      #
      # FPS_OPTIMIZATION.md §2 applied to custom tags: a handler whose
      # output is a PURE function of (attrs, store, style, region)
      # replays from the paint cache instead of re-running every frame
      # (Ui#cached_subtree does the capture/replay). Opt-in per tag —
      # `widget :panel, cache: true` — because purity is the tag
      # library's promise, not the renderer's to verify: a stateful
      # handler (time-driven visuals, edit state, popups) would freeze
      # on replay. The `cache:` mark doubles as the purity mark for
      # ANCESTOR walks: a cached panel may only contain other marked
      # tags and inert builtins (row/column), never a repeat (row set
      # is dynamic) or a conditional (if=/unless= — structure changes
      # with the store).
      #
      # The key folds everything a pure handler's output depends on:
      # the node's path (site identity — repeat rows re-path per row),
      # every attr of every node in the subtree (dynamic {…} attrs
      # re-interpolated each frame — row content changes miss), the
      # class-resolved style bags (object identity — a rule/look change
      # mints fresh bags, see paint_cache.cr) and the hover/active
      # verdict of the "/hover" interact id (the common on_click
      # convention of tag libraries; absent ids read nil forever).
      # The appear-run PRESENCE fold keeps a re-appearance (back nav)
      # a miss — the handler must run to restart the entrance
      # animation — while a settled run lingering in Memory keeps
      # steady frames hitting.
      #
      # ── memoized fold (push-дифф §8, ч.1) ─────────────────────────
      # The attr fold re-interpolates every dynamic template of the
      # subtree each frame just to learn nothing changed — the walk's
      # remaining value-diff tax. Instead, the store VERSIONS each
      # slot name (Runtime::SlotHash) and the memo records which names
      # the subtree's templates read plus their versions at fold time;
      # when none moved (and the style/document epochs hold), the last
      # fold is returned as-is — the interpolated values are provably
      # identical, so the hash is too. The dependency NAME list is
      # extracted statically from the raw templates (same regex as
      # #interpolate). Row scopes (repeat) never memoize: their store
      # is rebuilt per frame, versions restart. EGUI_PULLDIFF=1 turns
      # the memo off (fold every frame — the pre-push-diff behavior).
      private class KeyMemo
        getter fold : UInt64
        getter cls : String
        getter resolve_id : UInt64
        getter resolve_hover_id : UInt64
        getter names : Array(String)
        getter vers : Array(UInt64)
        getter vals : Array(String)
        getter style_ver : UInt64
        getter doc_ver : UInt64

        def initialize(@fold, @cls, @resolve_id, @resolve_hover_id,
                       @names, @vers, @vals, @style_ver, @doc_ver)
        end
      end

      @key_memo = {} of String => KeyMemo
      @key_names = {} of String => Array(String)
      @doc_version = 0u64

      # The {name} placeholder regex — the SAME literal #interpolate
      # walks; name extraction must never diverge from resolution.
      INTERP_NAME = /\{([a-zA-Z_][\w.]*)\}/

      private def custom_subtree_key(node : Node, ui : Ui, ctx : Context,
                                     rt : Runtime) : UInt64?
        return nil unless Exml.cacheable_tags.includes?(node.name)
        # Only containers: the win is skipping a whole SUBTREE. A
        # childless tag's handler costs about what a replay does —
        # wrapping it would be pure overhead (it still dispatches when
        # its parent panel is not cacheable, e.g. holds a <vis>).
        if node.children.empty?
          Egui::Bench.count("exml.key.leaf")
          return nil
        end
        if node.attrs["scroll"]? # a ScrollArea holds state
          Egui::Bench.count("exml.key.scroll")
          return nil
        end
        # Outside the ambient clip the capture rules would refuse to
        # store anyway (a subtree entry must be fully clip-contained),
        # so a below-the-fold scroll row would MISS forever — paying
        # the key fold and capture bookkeeping on top of the full
        # render. Skip before any of that work: a node starting below
        # the clip, or (with a static height attr) ending above it.
        clip = ui.clip
        if ui.cursor.y >= clip.max.y
          Egui::Bench.count("exml.key.below")
          return nil
        end
        if (hs = node.attrs["h"]?) && (hh = hs.to_f?)
          # известная статическая высота: попытка только у полностью
          # видимого узла (частично видимый ряд никогда не сохранится)
          if ui.cursor.y + hh > clip.max.y || ui.cursor.y + hh <= clip.min.y
            Egui::Bench.count("exml.key.straddle")
            return nil
          end
        end
        unless subtree_pure?(node)
          Egui::Bench.count("exml.key.impure")
          return nil
        end
        cls = (raw = node.attrs["class"]?) ?
                (raw.includes?('{') ? rt.interpolate(raw) : raw) : ""
        style_ver = ctx.stylesheet.version
        if (memo = key_memo_hit?(node, rt, cls, style_ver))
          Egui::Bench.count("exml.key.memo")
          return {node.path, memo.fold, memo.resolve_id,
                  memo.resolve_hover_id, fold_hover_states(node, ctx),
                  subtree_generation(node)}.hash
        end
        Egui::Bench.count("exml.key.fold")
        fold = fold_subtree(node, rt)
        names = (@key_names[node.path] ||= subtree_dep_names(node))
        @key_memo[node.path] = KeyMemo.new(fold, cls,
          ctx.stylesheet.resolve(cls).object_id,
          ctx.stylesheet.resolve(cls, "hover").object_id,
          names, names.map { |n| rt.slot_version(n) },
          names.map { |n| rt.lookup(n) || "" },
          style_ver, @doc_version)
        {node.path,
         fold,
         ctx.stylesheet.resolve(cls).object_id,
         ctx.stylesheet.resolve(cls, "hover").object_id,
         fold_hover_states(node, ctx),
         subtree_generation(node)}.hash
      end

      # The memo serves this frame iff the subtree's dependencies, the
      # style epoch and the document epoch all hold — the folded attr
      # hash is then provably identical to last frame's. Two check
      # modes, one per store flavor:
      #
      # - a LONG-LIVED store (root, component scopes) compares SLOT
      #   VERSIONS — O(1) hash reads, zero allocations;
      # - a ROW scope (repeat) is rebuilt each frame, its versions
      #   restart — there the dependency VALUES are compared instead
      #   (the same #lookup interpolation resolves through, so equal
      #   values fold to an equal hash; a row's own fields differ per
      #   row and keep rows apart). The value walk is still cheaper
      #   than the fold: unique names, no attr hashing, no templates.
      private def key_memo_hit?(node : Node, rt : Runtime, cls : String,
                                style_ver : UInt64) : KeyMemo?
        return nil if Egui.pull_diff?
        memo = @key_memo[node.path]?
        return nil unless memo
        return nil unless memo.cls == cls &&
                          memo.style_ver == style_ver &&
                          memo.doc_ver == @doc_version
        names = memo.names
        if rt.cache_interpolations?
          i = 0
          while i < names.size
            return nil if rt.slot_version(names[i]) != memo.vers[i]
            i += 1
          end
        else
          i = 0
          while i < names.size
            return nil if (rt.lookup(names[i]) || "") != memo.vals[i]
            i += 1
          end
        end
        memo
      end

      # The slot names a subtree's attr templates read — extracted
      # statically (INTERP_NAME over every attr of every descendant),
      # computed once per path. Must stay in lockstep with what
      # #fold_subtree hashes: every dynamic value it interpolates is
      # resolved through exactly these names.
      private def subtree_dep_names(node : Node) : Array(String)
        names = [] of String
        walk_dep_names(node, names)
        names.uniq!
        names
      end

      private def walk_dep_names(node : Node, names : Array(String)) : Nil
        node.attrs.each_value do |v|
          v.scan(INTERP_NAME) { |m| names << m[1] }
        end
        node.children.each { |c| walk_dep_names(c, names) }
      end

      # The hover/active verdicts of every custom node in the subtree
      # (root included), folded into one UInt64. Child tags paint their
      # own hover feedback (ibtn, chip, navitem …) from their interact
      # id — the root's verdict alone would replay a stale child hover,
      # so any child's flip must re-key the whole subtree. Both id
      # conventions are folded: "#{path}/hover" (the on_click panels)
      # and the bare "#{path}" (ibtn/navitem/chip/…). Absent ids read
      # nil forever (Memory#interaction_state mirrors the verdict
      # deterministically), so pure children cost two hash lookups
      # each and nothing else. Inert row/column containers recurse
      # through (they never interact themselves).
      private def fold_hover_states(node : Node, ctx : Context) : UInt64
        path = node.path
        id = node.id
        h = ctx.memory.interaction_state(id).hash &
            ctx.memory.interaction_state(
              Egui::Id.from("#{path}/hover")).hash
        node.children.each do |c|
          case c.kind
          when .custom?, .row?, .column?
            h = h &* 1_000_003 &+ fold_hover_states(c, ctx)
          end
        end
        h
      end

      # Appearance generation: bumps every time the node was NOT
      # rendered last frame (a hidden `if=` branch came back, a page
      # re-appeared). Folded into the key, a re-appearance is always a
      # miss — the handler must run to restart its entrance animation
      # (a stale small-cache entry can never serve it; large caches
      # evict, small ones never do). The generation counter itself
      # keeps the appear-run liveness question OUT of the key: a
      # settled run lingering in Memory is fine, and the frame-1 entry
      # (stored before the run existed) can never collide with a
      # steady-frame key again.
      private def subtree_generation(node : Node) : Int32
        path = node.path
        unless @subtree_last.includes?(path)
          @subtree_gens[path] = (@subtree_gens[path]? || 0) + 1
        end
        @subtree_cur << path
        @subtree_gens[path].not_nil!
      end

      # Fold one node's name + attrs (dynamic ones re-interpolated),
      # then its children recursively. UInt64 overflow wraps — the
      # chain is a plain rolling hash, same trade as the paint cache.
      private def fold_subtree(node : Node, rt : Runtime) : UInt64
        h = node.name.hash
        node.attrs.each do |k, v|
          h = h &* 1_000_003 &+ k.hash
          h = h &* 1_000_003 &+
              (v.includes?('{') ? rt.interpolate(v) : v).hash
        end
        node.children.each { |c| h = h &* 1_000_003 &+ fold_subtree(c, rt) }
        h
      end

      # The subtree may only hold `cache:`-marked custom tags and inert
      # row/column builtins, with no conditionals anywhere inside.
      private def subtree_pure?(node : Node) : Bool
        return false if node.if_cond || node.unless_cond
        node.children.all? do |c|
          case c.kind
          when .row?, .column?
            subtree_pure?(c)
          when .custom?
            Exml.cacheable_tags.includes?(c.name) && subtree_pure?(c)
          else
            false
          end
        end
      end

      # `<repeat for="doc" in="docs" key="id">` — the v-for, Python
      # reading order ("repeat for doc in docs"): `for` names the row
      # variable (default "item"), `in` the list slot. One scope per
      # row, the row's fields FLATTENED into it as "doc.<field>" (so
      # `{doc.name}` and `bind` need no changes), plus "_i" (the row
      # index, displayable as {_i}). Children are re-pathed per row —
      # under the `key` field's value when given (stable ids across
      # reorders, Vue's :key lesson), under the index otherwise.
      # Firing an action from a row writes "_i" into the ROOT store
      # first — list actions know which row fired.
      private def render_repeat(node : Node, ui : Ui, ctx : Context,
                                rt : Runtime) : Nil
        over = rt.interpolate(node.repeat_in || "")
        as_name = node.repeat_for || "item"
        key_field = node.repeat_key

        unless rt.rows?(over)
          unless @warned_custom.includes?("repeat:#{over}")
            @warned_custom << "repeat:#{over}"
            STDERR.puts "exml: <repeat in=\"#{over}\"> — no such list" \
                        " slot; publish it as rt.rows[\"#{over}\"]"
          end
          return
        end

        rt.rows?(over).not_nil!.each_with_index do |row, i|
          Egui::Bench.count("exml.row")
          scope = ScopedRuntime.new(rt)
          row.each { |k, v| scope.strings["#{as_name}.#{k}"] = v }
          scope.strings["_i"] = i.to_s
          if (alias_name = node.repeat_index_alias)
            scope.strings[alias_name] = i.to_s
          end
          scope.repeat_index = i
          seg = (key_field.try { |kf| row[kf]? } || "i#{i}")
          node.children_under("#{node.path}/#{seg}").each do |child|
            render(child, ui, ctx, scope)
          end
        end
      end

      # `<openfile>`/`<savefile>`: a button driving the native file
      # dialog (SystemPorts, fiber-backed — the frame loop never
      # blocks) plus a label showing the bound slot's path. The button
      # text walks three states — idle (`text=`, default "Open…"/
      # "Save…"), choosing (`text_choosing=`, while the dialog is up)
      # and chosen (`text_done=`, the slot holds a path). The choosing
      # flag lives in the store under "<bind>/choosing" — it survives
      # renderer rebuilds and stays readable from markup
      # (`{src/choosing}`); a cancel keeps the old slot value and the
      # state falls back to what it was. The path label carries the
      # class "file-label" (overridable via `label_class=`) for
      # styling, including the `visible: false` style key — the
      # display:none way to turn the label off. `filters=` is a
      # pipe-separated glob list ("*.png|*.jpg"); savefile's suggested
      # name is `default_name=`, falling back to the chosen path's
      # basename. `on_change=` fires after a successful pick.
      # `<openfile multiple>` picks several files: the bound string
      # slot holds the newline-JOINED paths (split with '\n' from app
      # code), the label shows the first path plus " (+N)" when more
      # than one file is chosen.
      private def render_file_picker(node : Node, ui : Ui, ctx : Context,
                                     rt : Runtime, save : Bool) : Nil
        key = node.bind_key || ""
        choosing_key = "#{key}/choosing"
        path = rt.string(key)
        choosing = rt.bool(choosing_key)
        idle = text_of(node, rt, save ? "Save…" : "Open…")
        text = if choosing
          node.file_choosing_text.try { |t| rt.interpolate(t) } || idle
        elsif !path.empty?
          node.file_done_text.try { |t| rt.interpolate(t) } || idle
        else
          idle
        end

        ui.horizontal do |h|
          if h.button(text, id: node.path).clicked? && !choosing
            rt.bools[choosing_key] = true
            title = node.title_attr.try { |t| rt.interpolate(t) } ||
                    (save ? "Save file" : "Open file")
            filters = node.file_filters
            directory = node.file_directory.try { |d| rt.interpolate(d) }
            done = ->(picked : String?) do
              rt.bools[choosing_key] = false
              if picked
                rt.strings[key] = picked
                fire_named(node.on_change, rt)
              end
            end
            if save
              Egui::SystemPorts::SaveFileDialog.show(
                title: title, filters: filters, directory: directory,
                default_name: node.file_default_name.try { |n| rt.interpolate(n) } ||
                              (path.empty? ? nil : File.basename(path))) do |picked|
                done.call(picked)
              end
            elsif node.file_multiple?
              done_multi = ->(paths : Array(String)?) do
                done.call(paths.try(&.join('\n')))
              end
              Egui::SystemPorts::OpenFileDialog.show_multiple(
                title: title, filters: filters, directory: directory) do |paths|
                done_multi.call(paths)
              end
            else
              Egui::SystemPorts::OpenFileDialog.show(
                title: title, filters: filters, directory: directory) do |picked|
                done.call(picked)
              end
            end
          end
          next if path.empty?
          raw_cls = node.file_label_class || "file-label"
          label_cls = raw_cls.includes?('{') ? rt.interpolate(raw_cls) : raw_cls
          next if ctx.stylesheet.resolve(label_cls).bool?("visible") == false
          shown = path
          if node.file_multiple? && (parts = path.split('\n')) && parts.size > 1
            shown = "#{parts.first} (+#{parts.size - 1})"
          end
          h.with_style_scope(label_cls) { |s| s.label(shown) }
        end
      end

      # The multi-line editor. With `editor_id` the textarea runs in a
      # child Ui id'd by the INTERPOLATED attribute — per-tab editors,
      # each keeping its own caret/selection — and a changed id takes
      # keyboard focus (focus follows the tab, the notepad idiom).
      private def render_textarea(node : Node, ui : Ui, ctx : Context,
                                  rt : Runtime) : Nil
        key = node.bind_key || ""
        hint = node.hint_attr
        rows = node.rows_count
        frame = node.framed
        on_act = node.on_change

        if editor_attr = node.editor_id
          editor_id = rt.interpolate(editor_attr)
          # fill_child: the editor fills the container remainder (the
          # fill-editor pattern, clamped to the visible fold — see
          # Ui#fill_child).
          editor = ui.fill_child(Egui::Id.from(editor_id))
          resp = editor.textarea(rt.string(key), hint: hint, rows: rows,
            frame: frame) do |t|
            rt.strings[key] = t
            rt.fire(on_act.not_nil!) if on_act
          end
          ref_set(node, resp)
          if editor_id != @last_editor_id
            @last_editor_id = editor_id
            ctx.memory.focus.request(resp.id)
          end
        else
          ref_set(node, ui.textarea(rt.string(key), hint: hint, rows: rows,
            frame: frame) do |t|
            rt.strings[key] = t
            rt.fire(on_act.not_nil!) if on_act
          end)
        end
      end

      # ── window frame ────────────────────────────────────────────────

      # `style=` of a frame element → the WindowFrame::Style (unknown
      # names fall back to Windows, warn-once); `{placeholder}` values
      # re-resolve every frame — a live theme switch.
      private def frame_style_of(node : Node,
                                 rt : Runtime) : Egui::WindowFrame::Style
        raw = node.frame_style.try { |s| rt.interpolate(s) } || "windows"
        Egui::WindowFrame.parse_style?(raw) ||
          Egui::WindowFrame::Style::Windows
      end

      # <window-frame-custom>: the explicit caption composition. The
      # <window-button> children name the button set (laid out in the
      # style's cluster idiom); every OTHER child renders INTO the
      # caption's content area (tabs, a search strip) in tree order —
      # with content present the title text is not painted (the
      # WindowFrame caption-hook idiom, now markup). A button's
      # on_click= replaces the native action; without it minimize /
      # maximize / close do what they always did.
      private def render_window_frame_custom(node : Node, ui : Ui,
                                             ctx : Context,
                                             rt : Runtime) : Nil
        # `if=`/`unless=` gate a button out of the set (hide maximize in
        # a dialog); content children check their own gates in #render.
        buttons = node.children.select(&.kind.window_button?)
          .select { |b| visible?(b, rt) }
        content = node.children.reject(&.kind.window_button?)
        content_proc = if content.empty?
          nil
        else
          # Rendered inside the frame's draw, at the caption's content
          # area: a child Ui over the area on the caption-content layer
          # (above the drag strip, below the caption buttons — the
          # TitleBarTabs layering).
          ->(c : Context, area : Rect) do
            cap = ui.child_ui(area, Id.from(node.path))
            cap.layer = LayerId.new(Order::Middle,
              Id.from("window_frame/content"), 40)
            cap.clip = area
            content.each { |child| render(child, cap, c, rt) }
          end
        end
        spec = buttons.map do |b|
          name = rt.interpolate(b.button_type || "close")
          {name, b.on_click.nil?}
        end
        drawn = Egui::WindowFrame.show_custom(ctx,
          interp(node.title_attr, rt) || "", frame_style_of(node, rt),
          height: node.frame_height, buttons: spec, content: content_proc)
        drawn.each_with_index do |(name, resp), i|
          if (act = buttons[i]?.try(&.on_click)) && resp.clicked?
            fire_named(act, rt)
          end
        end
      end

      # ── helpers ──────────────────────────────────────────────────────

      # Markup hotkeys (`@keyup.enter="save"` → `hotkey="enter"` +
      # `on_keyup="save"`): the key is WINDOW-global (like Vue's
      # document-level listener), fired through the regular HotkeyMap.
      # The binding rides the map namespaced `exml:<action>`; the
      # firing is consumed HERE and routed to the store's registered
      # proc (rt.fire) — the app's own HotkeyActions never collide.
      # Binding repeats every frame (idempotent); a markup binding
      # replaces an app one bound earlier — markup binds last, markup
      # wins — and lapsing with visibility returns the key (see
      # #render_routes). Skipped in a flex measure pass: the consume
      # is exactly-once state, the real pass must see it.
      private def bind_hotkey(node : Node, ui : Ui, ctx : Context,
                              rt : Runtime) : Nil
        hk_attr = node.hotkey_attr || return
        act = node.on_key_event || return
        return unless hotkey = Hotkey.parse?(rt.interpolate(hk_attr))
        name = rt.interpolate(act)
        action = HotkeyAction.new("exml:#{name}")
        ctx.hotkeys.bind(hotkey, action)
        @markup_hotkeys << hotkey
        return if ui.measuring?
        rt.fire(name) if ctx.consume_action(action)
      end

      private def interp(text : String?, rt : Runtime) : String?
        text.try { |t| rt.interpolate(t) }
      end

      # Register a widget's Response under its `id=` attr (the
      # template-ref bridge, see #ref); returns the response so call
      # sites compose (`ref_set(node, ui.button(…)).clicked?`).
      private def ref_set(node : Node, response : Response) : Response
        if (name = node.ref_name)
          @refs[name] = response
        end
        response
      end

      # The `text` attribute interpolated, "" when absent.
      private def text_of(node : Node, rt : Runtime, default = "") : String
        node.text_attr.try { |t| rt.interpolate(t) } || default
      end

      private def visible?(node : Node, rt : Runtime) : Bool
        if cond = node.if_cond
          return false unless rt.bool(rt.interpolate(cond))
        end
        if cond = node.unless_cond
          return false if rt.bool(rt.interpolate(cond))
        end
        true
      end

      # The `visible` style key (a bool): a class rule
      # `.x { visible: false }` drops the element — and its subtree —
      # from the frame, the display:none cousin. Applies to every
      # element carrying `class=`; the label of a file picker reads it
      # separately (see render_file_picker). Unlike `if=/unless=`,
      # widget memory lives on by Id-path — same trade as v-show.
      private def style_visible?(node : Node, ctx : Context, rt : Runtime) : Bool
        raw = node.attrs["class"]?
        return true unless raw
        cls = raw.includes?('{') ? rt.interpolate(raw) : raw
        return true if cls.empty?
        ctx.stylesheet.resolve(cls).bool?("visible") != false
      end

      # Fire the (optional, possibly interpolated) named action.
      private def fire_named(name : String?, rt : Runtime) : Nil
        rt.fire(rt.interpolate(name)) if name
      end
    end

    # Global custom-widget handlers — what the top-level `widget`
    # sugar fills. Every Renderer consults them when its instance has
    # no handler of its own: `Renderer#on` stays the per-instance
    # override, and registration order never matters (a widget may be
    # declared after the renderer exists).
    class_property widgets = {} of String => Renderer::CustomHandler

    # Tags declared pure (the `cache: true` mark of the `widget`
    # sugar): candidates for Renderer's retained subtrees AND the only
    # custom tags a cached subtree may contain (see
    # Renderer#custom_subtree_key).
    class_property cacheable_tags = Set(String).new
  end
end

# `widget :name do |node, ui, ctx, rt, r| … end` — top-level sugar
# for `Renderer#on`: registers a custom element every renderer sees,
# no renderer plumbing at the call site. Instance `#on` still wins,
# so an app can override a shared widget locally.
#
#   widget :cpu_graph do |node, ui, ctx, rt, r|
#     series = GRAPHS[rt.interpolate(node.attrs["series"]? || "")]
#     rect = ui.allocate_space(Egui::Vec2.new(ui.available_width, 160.0))
#     SysMon.graph(ui.painter, rect, series, Time.relative, 100.0)
#   end
#                                  # NOT cache: — Time-relative
#
# `cache: true` ALSO promises the handler is a pure function of
# (attrs, store, style, region) — no time-driven output, no edit or
# popup state — letting the renderer replay its subtree from the
# paint cache (see Renderer#custom_subtree_key). A pure container
# (panel) keeps the mark even when its CHILDREN render through the
# regular dispatch: the purity walk checks the children's tags.
def widget(name : String | Symbol, cache : Bool = false,
            &handler : Egui::Exml::Renderer::CustomHandler) : Nil
  tag = name.to_s
  # Per-tag bench span: the span table answers "which block renders
  # worst" without hand-written spans per widget. Self time excludes
  # nested tags, so a panel's row excludes the cards it walks inside.
  inner = handler
  wrapped = ->(node : Egui::Exml::Node, ui : Egui::Ui,
               ctx : Egui::Context, rt : Egui::Exml::Runtime,
               r : Egui::Exml::Renderer) do
    Egui::Bench.span("exml.tag.#{tag}") { inner.call(node, ui, ctx, rt, r) }
  end
  Egui::Exml.widgets[tag] = wrapped
  Egui::Exml.cacheable_tags << tag if cache
end
