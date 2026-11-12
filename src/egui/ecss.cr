# `.ecss` — the egui.cr CSS: a debug-only style-diff file the runtime
# inspector writes live and the app re-loads on change, so interface
# tweaking happens in the running app and persists without copying
# anything by hand.
#
# An app opts in with the `enable_ecss` macro (bottom of this file):
#
#   class MyApp < Egui::App
#     enable_ecss "my_app"          # → <bin_dir>/style_my_app.ecss
#   end
#
# The macro expands only in debug builds (`flag?(:debug)`): release
# binaries never touch the file system for styles. `Sokol.run` starts
# the session (loading the file if present); from then on:
#
#   * every inspector edit (Class tab rules, Element tab overrides,
#     the color popup) is applied to the context AND recorded into the
#     session's document — nothing touches the disk until the header's
#     «Сохранить» button calls `#flush(force: true)`;
#   * `Context#begin_frame` stats the file: an external edit (a text
#     editor) reloads it live — hot reload in both directions;
#   * a theme swap re-applies the class rules (a new `Theme` brings a
#     fresh `StyleSheet`).
#
# The document holds ONLY the inspector's edits — the diff on top of
# the app's own theme/user-agent rules — never a dump of the whole
# `StyleSheet`, so later code changes to the theme are not shadowed.
#
# Format (see `Doc#to_s`):
#
#   button {
#     background: #3d3d3dff;
#     padding.top: 4;
#   }
#   button:hover {
#     background: #5a5a5aff;
#   }
#   #save:active {          /* element override, explicit widget id */
#     background: #ff8800ff;
#   }
#
# Border keys are four-sided like padding: the scalar `stroke_width`
# sets every side (with `stroke` the shared color), and the per-side
# `stroke_width.top/right/bottom/left` override one side — width 0
# turns the side off (CSS `border-style: solid none none none` is
# `stroke_width: 1; stroke_width.right: 0; stroke_width.bottom: 0;
# stroke_width.left: 0`). Per-side colors ride `stroke.<side>`.
#
# Values: colors `#rgb`/`#rrggbb`/`#rrggbbaa`, numbers, `true`/`false`,
# quoted strings (font families), and the `spring(…)` transition value
# (`transition: background spring(bouncy)` / `transition: width
# spring(0.3, 0.8) 50ms`). The parser is deliberately lenient —
# a half-typed line in a live-edited file must cost a warning on
# STDERR, not a crash; only the declarations that fully parse apply.
# Auto-id (`#0x…`) element rules are filtered out with a warning: a
# raw auto id means nothing in another process, so only explicitly
# named widgets persist element overrides.

module Egui
  module Ecss
    # The .ecss format version this build speaks. Files carry the
    # version in the `@ecss vN;` directive (first line, written by
    # `Doc#to_s`); a file claiming a NEWER version parses with a loud
    # warning — unknown syntax of future versions is skipped leniently,
    # not a crash (files are live-edited in text editors).
    ECSS_VERSION = 1

    # One element-override entry of the document: a widget with an
    # EXPLICIT id (serialized as `#save`) holding a base bag plus
    # per-state overlays, the same shape `StyleClass` gives class
    # rules. Auto-id widgets never make it into the document — their
    # raw values are meaningless in another process, so they are
    # filtered out on record AND on parse (with a warning).
    class ElementEntry
      getter id : Id
      getter name : String
      getter vars : StyleVars
      getter states : Hash(String, StyleVars)

      def initialize(@id, @name)
        @vars = StyleVars.new
        @states = {} of String => StyleVars
      end

      def target : String
        @name
      end

      def empty? : Bool
        @vars.empty? && @states.all? { |_st, bag| bag.empty? }
      end
    end

    # The parsed document: class rules (dotted paths → `StyleClass`)
    # plus element overrides (`Id` → `ElementEntry`) and media-gated
    # class rule blocks (`@media (…) { … }`). Built by `#record_*`
    # edits or `.parse`; written by `#to_s`.
    class Doc
      def initialize
        @classes = {} of String => StyleClass
        @elements = {} of UInt64 => ElementEntry
        # One bucket per DISTINCT media condition, declaration order —
        # same {path → StyleClass} shape as the unconditional rules.
        @media = [] of {MediaCond, Hash(String, StyleClass)}
        # Named @keyframes tracks (plans/NativeHTML.md §7) — kept
        # parsed; `Session#apply_doc` writes them into the stylesheet.
        @keyframes = {} of String => KeyframeTrack
        # The version this document was parsed from / will be written
        # as (`@ecss vN;`). Files without the directive parse as the
        # current version (v1 predates the directive).
        @version = ECSS_VERSION
      end

      getter classes : Hash(String, StyleClass)
      getter elements : Hash(UInt64, ElementEntry)
      getter media : Array({MediaCond, Hash(String, StyleClass)})
      getter keyframes : Hash(String, KeyframeTrack)
      # Written by .parse_version (the `@ecss vN;` directive) — outside
      # code reads it, only the parser sets it.
      getter version : Int32
      protected def version=(version : Int32)
        @version = version
      end

      def empty? : Bool
        @classes.all? { |_p, c| c.vars.empty? && c.states.all? { |_s, b| b.empty? } } &&
          @elements.all? { |_i, e| e.empty? } &&
          @media.all? do |_cond, classes|
            classes.all? { |_p, c| c.vars.empty? && c.states.all? { |_s, b| b.empty? } }
          end
      end

      # "button:hover" → {"button", "hover"}; "button" → {"button", nil}.
      # Delegates to `StyleSheet.split_selector` — the ONE splitter of
      # the cascade (this used to be a byte-identical copy).
      def self.split_selector(selector : String) : {String, String?}
        StyleSheet.split_selector(selector)
      end

      # Merge one key into a class rule (creating the class on first
      # touch, like `StyleSheet#rule`). With `media` the rule lands in
      # that condition's bucket instead (created on first touch).
      def set_class(path : String, state : String?, key : String,
                    value : StyleValue, media : String? = nil) : Nil
        if media && (cond = MediaCond.parse(media))
          classes = (@media.find { |c, _| c == cond } || begin
            bucket = {cond, {} of String => StyleClass}
            @media << bucket
            bucket
          end)[1]
          cls = (classes[path] ||= StyleClass.new(path))
          state ? cls.set(state, StyleVars{key => value}) : cls.set(StyleVars{key => value})
        else
          cls = (@classes[path] ||= StyleClass.new(path))
          state ? cls.set(state, StyleVars{key => value}) : cls.set(StyleVars{key => value})
        end
      end

      # Remove one key; true when the document changed. Drops the rule
      # entirely once every bag is empty, so the file never accumulates
      # `button { }` husks. With `media` only that condition's bucket
      # is touched.
      def unset_class(path : String, state : String?, key : String,
                      media : String? = nil) : Bool
        cond = media ? MediaCond.parse(media) : nil
        classes = cond ? @media.find { |c, _| c == cond }.try &.[1] : @classes
        return false unless classes && (cls = classes[path]?)
        if state
          cls.states[state]?.try &.delete(key)
          cls.states.delete(state) if cls.states[state]?.try &.empty?
        else
          cls.vars.delete(key)
        end
        if cls.vars.empty? && cls.states.all? { |_st, bag| bag.empty? }
          classes.delete(path)
        end
        if cond && classes.empty?
          @media.reject! { |c, _| c == cond }
        end
        true
      end

      # Merge one key into an element override (state-scoped like the
      # class rules). `name` fills the entry's explicit id name when it
      # was only known by its raw value so far.
      # Merge one key into an element override (state-scoped like the
      # class rules). `name` is required: only explicitly-named widgets
      # are addressable across restarts, so a nil-name (auto-id) edit
      # is silently not recorded — it still applies live through the
      # Context, it just never persists to the file.
      def set_element(id : Id, name : String?, state : String?,
                      key : String, value : StyleValue) : Nil
        return unless name
        entry = (@elements[id.value] ||= ElementEntry.new(id, name))
        bag = state ? (entry.states[state] ||= StyleVars.new) : entry.vars
        bag[key] = value
      end

      # Remove one key from an element rule; true when something was
      # actually dropped (empty bags and empty entries go away).
      def unset_element(id : Id, state : String?, key : String) : Bool
        return false unless (entry = @elements[id.value]?)
        if state
          entry.states[state]?.try &.delete(key)
          entry.states.delete(state) if entry.states[state]?.try &.empty?
        else
          entry.vars.delete(key)
        end
        @elements.delete(id.value) if entry.empty?
        true
      end

      # Wipe EVERY rule of one element (the inspector's "Reset all").
      def clear_element(id : Id) : Bool
        !!@elements.delete(id.value)
      end

      # Introspection for specs/tests: the base-or-state bag of a class
      # rule, nil when absent or empty.
      def class_vars(path : String, state : String?) : StyleVars?
        cls = @classes[path]?
        bag = state ? cls.try &.states[state]? : cls.try &.vars
        bag.try { |b| b.empty? ? nil : b }
      end

      def element(id : Id) : ElementEntry?
        @elements[id.value]?
      end

      # --- serialization -------------------------------------------------

      def to_s(io : IO) : Nil
        io << "@ecss v#{@version};\n"
        io << "/* egui.cr style diff (written by the inspector's save button) */\n"
        @classes.keys.sort.each do |path|
          cls = @classes[path]
          write_rule(io, path, cls.vars)
          cls.states.keys.sort.each do |state|
            write_rule(io, "#{path}:#{state}", cls.states[state])
          end
        end
        @media.each do |cond, classes|
          io << '\n' << "@media " << cond << " {\n"
          classes.keys.sort.each do |path|
            cls = classes[path]
            write_rule(io, path, cls.vars, "  ")
            cls.states.keys.sort.each do |state|
              write_rule(io, "#{path}:#{state}", cls.states[state], "  ")
            end
          end
          io << "}\n"
        end
        @keyframes.keys.sort.each do |name|
          track = @keyframes[name]
          io << '\n' << "@keyframes " << name << " {\n"
          track.stops.each do |pos, vars|
            label = pos <= 0.0 ? "from" : pos >= 1.0 ? "to"
              : "#{(pos * 100).round.to_i}%"
            write_rule(io, label, vars, "  ")
          end
          io << "}\n"
        end
        @elements.values.sort_by(&.target).each do |entry|
          write_rule(io, "##{entry.target}", entry.vars) unless entry.vars.empty?
          entry.states.keys.sort.each do |state|
            write_rule(io, "##{entry.target}:#{state}", entry.states[state])
          end
        end
      end

      private def write_rule(io : IO, selector : String, vars : StyleVars,
                             indent : String = "") : Nil
        return if vars.empty?
        io << '\n' << indent << selector << " {\n"
        vars.keys.sort.each do |key|
          io << indent << "  " << key << ": " << Doc.format_value(vars[key]) << ";\n"
        end
        io << indent << "}\n"
      end

      # The value spelling: colors as `#rrggbbaa` (the same lowercase
      # hex `StyleSheet#dump` uses), whole numbers without the `.0`,
      # unit lengths as written (`50%`, `10vw`, `1.5rem`), per-corner
      # rounding as the CSS shorthand (`0 8 16 2`).
      def self.format_value(v : StyleValue) : String
        case v
        when Color32
          sprintf("#%02x%02x%02x%02x", v.r, v.g, v.b, v.a)
        when Gradient
          v.to_s
        when CornerRadii
          v.to_s
        when Float64
          v % 1 == 0 ? v.to_i64.to_s : v.to_s
        when StyleLength
          v.to_s
        when String
          v.inspect
        else
          v.to_s
        end
      end

      # --- parsing ---------------------------------------------------------

      # Lenient parse: whatever fully parses becomes a rule; everything
      # else is a one-line STDERR warning (the file is live-edited in
      # text editors — a half-typed declaration must not kill the app).
      # `@media (cond) { …rules… }` blocks gate every rule inside them;
      # nesting @media inside @media is a warning-and-ignore.
      def self.parse(text : String) : Doc
        doc = Doc.new
        pos = 0
        media : String? = nil # inside an @media block
        size = text.size
        loop do
          pos = skip_blank(text, pos)
          break if pos >= size
          if text[pos] == '}'
            pos += 1
            media = nil if media # the @media block's closing brace
            next
          end
          # `@ecss v1;` — the version directive, one line, no block.
          # Read to end-of-line before the '{' hunt (the directive
          # carries no brace of its own).
          if text[pos, 5].downcase == "@ecss"
            eol = text.index('\n', pos) || size
            parse_version(doc, text[pos...eol].strip)
            pos = eol
            next
          end
          brace = text.index('{', pos)
          if brace.nil?
            warn "trailing text with no '{' — ignored"
            break
          end
          selector = text[pos...brace].strip
          close = text.index('}', brace + 1)
          if close.nil?
            warn "missing '}' — the rest of the file is ignored"
            close = size
          end
          # `@keyframes name { from { … } to { … } }` — nested braces,
          # so the block ends at the MATCHING close, not the next one.
          if selector.downcase.starts_with?("@keyframes")
            kclose = match_brace(text, brace)
            if kclose.nil?
              warn "@keyframes block without matching '}' — ignored"
              break
            end
            parse_keyframes(doc, selector[10..].strip,
              text[(brace + 1)...kclose])
            break if kclose >= size
            pos = kclose + 1
            next
          end
          if selector.downcase.starts_with?("@media")
            cond = selector[6..].strip
            if (parsed = MediaCond.parse(cond))
              media = parsed.to_s
            else
              warn "@media #{cond.inspect} is not a supported media \
condition — block ignored"
              media = "@ignored" # swallow until the closing brace
            end
            # Step INSIDE the block: the inner rules parse as normal
            # top-level rules with the media context riding along, and
            # the block's own closing '}' (the standalone one) clears
            # it above.
            pos = brace + 1
            next
          elsif media != "@ignored"
            parse_rule(doc, selector, text[(brace + 1)...close], media)
          end
          break if close >= size
          pos = close + 1
        end
        doc
      end

      # `@ecss v1;` / `@ecss 2` — stamp the document version; a version
      # newer than this build warns (the lenient parse continues —
      # unknown future syntax is skipped, files are live-edited).
      # Index of the '}' matching the '{' at `open` (depth-counted);
      # nil when unclosed.
      private def self.match_brace(text : String, open : Int32) : Int32?
        depth = 0
        (open...text.size).each do |i|
          c = text[i]
          depth += 1 if c == '{'
          depth -= 1 if c == '}'
          return i if depth.zero? && c == '}'
        end
        nil
      end

      # The frames of an @keyframes block: "from"/"to"/"N%" selectors,
      # each with a plain declaration body.
      private def self.parse_keyframes(doc : Doc, name : String,
                                       body : String) : Nil
        if name.empty?
          warn "@keyframes without a name — ignored"
          return
        end
        pos = 0
        frames = {} of String => StyleVars
        size = body.size
        loop do
          pos = skip_blank(body, pos)
          break if pos >= size
          brace = body.index('{', pos)
          if brace.nil?
            warn "@keyframes #{name}: trailing text without '{' — ignored"
            break
          end
          label = body[pos...brace].strip
          close = body.index('}', brace + 1) || size
          vars = StyleVars.new
          each_decl(body[(brace + 1)...close]) { |k, v| vars[k] = v }
          frames[label] = vars unless label.empty? || vars.empty?
          break if close >= size
          pos = close + 1
        end
        if frames.empty?
          warn "@keyframes #{name}: no frames — ignored"
        else
          doc.keyframes[name] = KeyframeTrack.new(name, frames)
        end
      end

      private def self.parse_version(doc : Doc, directive : String) : Nil
        body = directive[5..].strip.rstrip(';').lstrip('v').strip
        if (v = body.to_i32?) && v > 0
          doc.version = v
          if v > ECSS_VERSION
            warn "@ecss v#{v} file, this build speaks v#{ECSS_VERSION} \
— unknown syntax may be skipped"
          end
        else
          warn "#{directive.inspect} is not an @ecss version — ignored"
        end
      end

      private def self.parse_rule(doc : Doc, selector : String,
                                  body : String, media : String? = nil) : Nil
        target, state = split_selector(selector)
        if target.empty?
          warn "empty selector — rule ignored"
          return
        end
        if target.starts_with?('#')
          name = target[1..]
          if name.empty?
            warn "empty element id — rule ignored"
            return
          end
          if name.starts_with?("0x")
            # Raw auto-id rules are useless in another process (an auto
            # id only means anything in the process that minted it) —
            # filter them out loudly so a stale file explains itself.
            warn "auto-id rule \##{name} ignored — give the widget an \
explicit id to persist element overrides"
            return
          end
          id = Id.from(name)
          each_decl(body) do |key, value|
            doc.set_element(id, name, state, key, value)
          end
        else
          each_decl(body) do |key, value|
            # Element (#id) overrides take no media condition in v1 —
            # they apply unconditionally even inside an @media block.
            doc.set_class(target, state, key, value, media)
          end
        end
      end

      # Yield every `key: value` pair of a rule body (';' separated,
      # quoting aware); broken values warn and drop their declaration.
      private def self.each_decl(body : String, & : String, StyleValue ->) : Nil
        strip_comments(body).split(';').each do |part|
          next if part.blank?
          ci = part.index(':')
          if ci.nil?
            warn "declaration without ':' — \"#{part.strip}\" ignored"
            next
          end
          key = part[0...ci].strip
          if key.empty?
            warn "empty property name — \"#{part.strip}\" ignored"
            next
          end
          # The CSS spelling of the engine's `rounding` key — the
          # same alias Html.box_style takes (`rounding: 0 8 16 2`
          # and `border-radius: 0 8 16 2` are one key).
          key = "rounding" if key == "border-radius"
          vs = part[(ci + 1)..].strip
          # `transition: background spring(bouncy)` — the CSS-shorthand
          # spelling: a bare leading identifier names the key the
          # spring applies to (recorded as the per-key
          # `transition.background`, exactly what the value reader
          # expects).
          if key == "transition" &&
             (split = Spring::Spec.split_shorthand(vs))
            key = "transition.#{split[0]}"
            vs = split[1]
          end
          if (value = parse_value(vs))
            yield key, value
          end
        end
      end

      private def self.parse_value(s : String) : StyleValue?
        case
        when s.empty?         then nil
        when s == "true"      then true
        when s == "false"     then false
        when s.starts_with?('#') then parse_color(s)
        when s.starts_with?('"')
          parse_string(s)
        when s == "spring" || s.starts_with?("spring(")
          # The `spring(…)` transition value (plans/NATIVE_HTML_DEMO.md
          # §3.2) — stored as its canonical spelling, parsed by
          # `Widget#transition_spring?`.
          if (spec = Spring::Spec.parse?(s))
            spec.to_s
          else
            warn "bad spring \"#{s}\" — ignored"
            nil
          end
        when s.starts_with?("linear-gradient(") ||
             s.starts_with?("radial-gradient(")
          # The `background-gradient` value — a full CSS-like gradient
          # (see `Egui::Gradient`); parsed here so the bag carries the
          # struct, not a string.
          if (g = Gradient.parse?(s))
            g
          else
            warn "bad gradient \"#{s}\" — ignored"
            nil
          end
        else
          if s.includes?(' ') && (c = CornerRadii.parse?(s))
            # The CSS `border-radius` shorthand (`rounding: 0 8 16 2`):
            # 1-4 radii expanded per the standard (CornerRadii.parse?).
            c
          elsif (n = s.to_f64?)
            n
          elsif s.ends_with?("px") && (n = s[0...s.size - 2].to_f64?)
            n # px is the default unit — a plain number, back-compat
          elsif time_value?(s)
            s # a time spelling ("80ms", "0.08s") — kept raw; readers
              # like AppearAnims.delay_from parse it (plain numbers
              # elsewhere mean milliseconds)
          elsif (l = StyleLength.parse?(s))
            l
          elsif (kw = bare_keyword?(s))
            kw # CSS keywords are bare identifiers (`rounding: capsule`);
               # quoted strings remain the form for values with spaces
               # (font families)
          else
            warn "unparseable value \"#{s}\" — ignored"
            nil
          end
        end
      end

      private def self.parse_color(s : String) : Color32?
        hex = s[1..]
        hex = hex.chars.map { |c| "#{c}#{c}" }.join if hex.size == 3 # #rgb → #rrggbb
        unless hex.size == 6 || hex.size == 8
          warn "bad color \"#{s}\" — ignored"
          return nil
        end
        r = hex_pair(hex, 0) || (return warn_color(s))
        g = hex_pair(hex, 2) || (return warn_color(s))
        b = hex_pair(hex, 4) || (return warn_color(s))
        a = hex.size == 8 ? (hex_pair(hex, 6) || return warn_color(s)) : 255_u8
        Color32.new(r, g, b, a)
      end

      private def self.warn_color(s : String) : Nil
        warn "bad color \"#{s}\" — ignored"
        nil
      end

      private def self.parse_string(s : String) : String?
        unless s.size >= 2 && s.ends_with?('"')
          warn "unterminated string #{s.inspect} — ignored"
          return nil
        end
        inner = s[1...-1]
        inner.gsub("\\\"", "\"").gsub("\\\\", "\\")
      end

      # A bare identifier value: letters/digits/dashes/underscores,
      # not starting with a digit (`capsule`, `ease-out`). Numbers,
      # colors, booleans and lengths are matched earlier, so what
      # reaches here used to be a warning — now it parses as a String
      # the typed getters ignore unless the key expects one.
      private def self.bare_keyword?(s : String) : String?
        return nil if s.empty? || s[0].number?
        s.each_char do |c|
          next if c.ascii_letter? || c.number? || c == '-' || c == '_'
          return nil
        end
        s
      end

      # "80ms" / "0.08s" — a number with a time unit (a bare number is
      # matched earlier and means milliseconds wherever a duration is
      # expected). Kept as the raw string spelling.
      private def self.time_value?(s : String) : Bool
        return false unless s.ends_with?("ms") || s.ends_with?('s')
        body = s.ends_with?("ms") ? s[0...s.size - 2] : s[0...s.size - 1]
        !body.empty? && !body.to_f64?.nil?
      end

      private def self.hex_val(c : Char) : Int32?
        case c
        when '0'..'9' then c - '0'
        when 'a'..'f' then c - 'a' + 10
        when 'A'..'F' then c - 'A' + 10
        else               nil
        end
      end

      private def self.hex_pair(s : String, i : Int32) : UInt8?
        hi = hex_val(s[i]? || return) || return
        lo = hex_val(s[i + 1]? || return) || return
        (hi * 16 + lo).to_u8
      end

      # Whitespace and both comment styles (`// … \n`, `/* … */`).
      private def self.skip_blank(text : String, pos : Int32) : Int32
        while pos < text.size
          case text[pos]
          when ' ', '\t', '\n', '\r' then pos += 1
          when '/'
            if text[pos + 1]? == '/'
              pos = text.index('\n', pos) || text.size
            elsif text[pos + 1]? == '*'
              pos = (text.index("*/", pos + 2) || {text.size - 2, 0}.max) + 2
            else
              return pos
            end
          else
            return pos
          end
        end
        pos
      end

      private def self.strip_comments(s : String) : String
        out = String::Builder.new
        i = 0
        in_string = false
        while i < s.size
          c = s[i]
          if in_string
            out << c
            in_string = false if c == '"' && s[i - 1]? != '\\'
            i += 1
          elsif c == '"'
            out << c
            in_string = true
            i += 1
          elsif c == '/' && s[i + 1]? == '/'
            i = s.index('\n', i) || s.size
          elsif c == '/' && s[i + 1]? == '*'
            i = (j = s.index("*/", i + 2)) ? j + 2 : s.size
          else
            out << c
            i += 1
          end
        end
        out.to_s
      end

      private def self.warn(msg : String) : Nil
        STDERR.puts "ecss: #{msg}"
      end
    end

    # The live debug session: owns the document, mirrors every edit
    # into the `Context` (class rules → `StyleSheet#rule`, element
    # overrides → `Context#set_id_style`) and reloads the file when it
    # changes on disk (`Context#begin_frame`). Nothing is written to
    # disk automatically — saving is explicit, the inspector header's
    # «Сохранить» button (`#flush(force: true)`). Started by
    # `Sokol.run` in debug builds via `.enable`; the app opts in with
    # the `enable_ecss` macro.
    class Session
      getter path : String
      getter doc : Doc
      @ctx : Context
      @dirty : Bool
      @last_mtime : Time?
      @last_size : Int64
      # What is currently applied to the context, with the value each
      # key had BEFORE the session first wrote it — the un-apply
      # journal a reload plays back first so keys DELETED from the file
      # fall back to the theme (or app) value, not into the void: ecss
      # rules merge into the SAME class bags the theme uses, so a bare
      # key-delete would take the theme's own value down with it.
      @applied_class : Array({String, String?, String, String?, StyleValue?})
      @applied_element : Array({Id, String?, String})
      # @keyframes tracks this session applied, with the track the
      # stylesheet had before (nil = none) — the un-apply journal.
      @applied_keyframes : Array({String, KeyframeTrack?})

      def self.enable(ctx : Context, app_id : String) : Session
        # A FLAT file next to the binary — no per-app subdirectory: the
        # natural dir name (<bin_dir>/<app_id>) collides with the app's
        # own binary (bin/apps/notepad is a FILE), so the id rides in the
        # file name instead: style_<app_id>.ecss.
        dir = File.dirname(File.expand_path(PROGRAM_NAME))
        session = new(ctx, File.join(dir, "style_#{app_id}.ecss"))
        ctx.ecss = session
        session
      end

      def initialize(@ctx, @path)
        @doc = Doc.new
        @dirty = false
        @last_mtime = nil
        @last_size = -1_i64
        @applied_class = [] of {String, String?, String, String?, StyleValue?}
        @applied_element = [] of {Id, String?, String}
        @applied_keyframes = [] of {String, KeyframeTrack?}
        return unless File.exists?(@path)
        begin
          remember_stat
          @doc = Doc.parse(File.read(@path))
          apply_doc
        rescue e
          STDERR.puts "ecss: failed to load #{@path}: #{e}"
        end
      end

      # --- recording (the inspector write-through funnel) ------------------

      # One class-rule edit (selector "button" / "button:hover"):
      # applied to the stylesheet, recorded into the document, file
      # marked dirty — flushed to disk at the end of the frame.
      # `media` ("(min-width: 600px)") targets that media rule.
      def record_class(selector : String, key : String,
                       value : StyleValue, media : String? = nil) : Nil
        path, state = Doc.split_selector(selector)
        @doc.set_class(path, state, key, value, media)
        journal_class(path, state, key, media)
        @ctx.stylesheet.rule(selector, StyleVars{key => value}, media)
        @dirty = true
      end

      # One class-rule key removal; a no-op on the file when the key
      # was never part of the diff (un-setting an app-defined rule).
      def unset_class(selector : String, key : String,
                      media : String? = nil) : Nil
        path, state = Doc.split_selector(selector)
        if (i = journal_class_index(path, state, key, media))
          restore_class(@applied_class.delete_at(i))
        else
          @ctx.stylesheet.unset(selector, key, media)
        end
        @dirty = true if @doc.unset_class(path, state, key, media)
      end

      def record_element(id : Id, name : String?, key : String,
                         value : StyleValue, state : String? = nil) : Nil
        @ctx.set_id_style(id, key, value, state)
        # Auto-id widgets are not persistable (their raw value means
        # nothing in another process) — the edit applies live, but the
        # document (and the file) only ever hold explicit-id elements.
        return unless name
        @doc.set_element(id, name, state, key, value)
        unless @applied_element.includes?({id, state, key})
          @applied_element << {id, state, key}
        end
        @dirty = true
      end

      def unset_element(id : Id, key : String, state : String? = nil) : Nil
        @ctx.clear_id_style(id, key, state)
        @applied_element.reject! { |t| t[0] == id && t[1] == state && t[2] == key }
        @dirty = true if @doc.unset_element(id, state, key)
      end

      # The Element tab's "Reset all": every state, every key.
      def clear_element(id : Id) : Nil
        @ctx.clear_id_style(id)
        @applied_element.reject! { |t| t[0] == id }
        @dirty = true if @doc.clear_element(id)
      end

      # --- file lifecycle ----------------------------------------------------

      # Write the document to disk. The ONLY caller is the inspector
      # header's «Сохранить» button (`force: true`) — recording an edit
      # (`#record_*` / `#unset_*`) just marks the document dirty; the
      # file stays untouched until the user saves.
      def flush(force : Bool = false) : Nil
        return if !@dirty && !force
        begin
          Dir.mkdir_p(File.dirname(@path))
          File.write(@path, @doc.to_s)
          remember_stat
          @dirty = false
        rescue e
          STDERR.puts "ecss: failed to write #{@path}: #{e}"
        end
      end

      # Hot reload: stat the file; an mtime/size change since the last
      # load/write replays the journal backwards (removing keys deleted
      # from the file) and applies the fresh document.
      def poll : Nil
        return unless File.exists?(@path)
        mtime = File.info(@path).modification_time
        size = File.size(@path)
        return if mtime == @last_mtime && size == @last_size
        @last_mtime = mtime
        @last_size = size
        reload
      end

      # A theme swap replaced the whole `StyleSheet` — bring the class
      # rules over to the new sheet (element overrides live on the
      # Context and survive, re-applying them is an idempotent no-op).
      def reapply : Nil
        unapply
        apply_doc
      end

      # --- internals -----------------------------------------------------------

      private def reload : Nil
        unapply
        @doc = Doc.parse(File.read(@path))
        apply_doc
        @ctx.request_repaint
      rescue e
        STDERR.puts "ecss: failed to reload #{@path}: #{e}"
      end

      private def apply_doc : Nil
        @doc.classes.each do |path, cls|
          apply_class(path, nil, cls.vars)
          cls.states.each do |state, vars|
            apply_class(path, state, vars)
          end
        end
        @doc.media.each do |cond, classes|
          classes.each do |path, cls|
            apply_class(path, nil, cls.vars, cond.to_s)
            cls.states.each do |state, vars|
              apply_class(path, state, vars, cond.to_s)
            end
          end
        end
        @doc.elements.each_value do |entry|
          apply_element(entry.id, nil, entry.vars)
          entry.states.each do |state, vars|
            apply_element(entry.id, state, vars)
          end
        end
        @doc.keyframes.each do |name, track|
          unless @applied_keyframes.any? { |n, _| n == name }
            @applied_keyframes << {name, @ctx.stylesheet.keyframe_track?(name)}
          end
          @ctx.stylesheet.keyframes(name, track)
        end
      end

      private def apply_class(path : String, state : String?,
                              vars : StyleVars, media : String? = nil) : Nil
        return if vars.empty?
        selector = state ? "#{path}:#{state}" : path
        vars.each do |key, value|
          journal_class(path, state, key, media)
          @ctx.stylesheet.rule(selector, StyleVars{key => value}, media)
        end
      end

      private def apply_element(id : Id, state : String?,
                                vars : StyleVars) : Nil
        vars.each do |key, value|
          @ctx.set_id_style(id, key, value, state)
          unless @applied_element.any? { |t| t[0] == id && t[1] == state && t[2] == key }
            @applied_element << {id, state, key}
          end
        end
      end

      # Remember `key` at this scope, capturing the value the cascade
      # had BEFORE the session's first write of it (kept as-is on
      # re-writes — the original value is what an un-apply restores).
      # Media entries never capture a prev: the media layer did not
      # exist before this session, so un-apply is always an unset.
      private def journal_class(path : String, state : String?,
                                key : String, media : String? = nil) : Nil
        return if journal_class_index(path, state, key, media)
        prev = media ? nil : @ctx.stylesheet.resolve(path, state)[key]?
        @applied_class << {path, state, key, media, prev}
      end

      private def journal_class_index(path : String, state : String?,
                                      key : String,
                                      media : String? = nil) : Int32?
        @applied_class.index do |t|
          t[0] == path && t[1] == state && t[2] == key && t[3] == media
        end
      end

      # Put one journaled key back: the captured pre-session value when
      # there was one (a theme/app rule), a plain unset otherwise.
      private def restore_class(
          entry : {String, String?, String, String?, StyleValue?}) : Nil
        path, state, key, media, prev = entry
        selector = state ? "#{path}:#{state}" : path
        if prev
          @ctx.stylesheet.rule(selector, StyleVars{key => prev})
        else
          @ctx.stylesheet.unset(selector, key, media)
        end
      end

      private def unapply : Nil
        @applied_class.each { |entry| restore_class(entry) }
        @applied_element.each do |id, state, key|
          @ctx.clear_id_style(id, key, state)
        end
        @applied_keyframes.each do |name, prev|
          if prev
            @ctx.stylesheet.keyframes(name, prev)
          else
            @ctx.stylesheet.remove_keyframes(name)
          end
        end
        @applied_class.clear
        @applied_element.clear
        @applied_keyframes.clear
      end

      private def remember_stat : Nil
        if File.exists?(@path)
          @last_mtime = File.info(@path).modification_time
          @last_size = File.size(@path)
        end
      end
    end
  end
end

# The app opt-in (call inside an `Egui::App` subclass body):
#
#   class MyApp < Egui::App
#     enable_ecss "my_app"
#   end
#
# Debug builds get `#ecss_app_id`, which `Sokol.run` picks up to start
# the `.ecss` session (the diff file lives next to the binary as
# `style_<app_id>.ecss`). Release builds expand to nothing — no
# methods, no file access, no cost.
macro enable_ecss(app_id)
  {% if flag?(:debug) %}
    def ecss_app_id : String
      {{app_id}}
    end
  {% end %}
end
