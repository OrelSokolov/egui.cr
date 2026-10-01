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
# Values: colors `#rgb`/`#rrggbb`/`#rrggbbaa`, numbers, `true`/`false`,
# quoted strings (font families). The parser is deliberately lenient —
# a half-typed line in a live-edited file must cost a warning on
# STDERR, not a crash; only the declarations that fully parse apply.
# Auto-id (`#0x…`) element rules are filtered out with a warning: a
# raw auto id means nothing in another process, so only explicitly
# named widgets persist element overrides.

module Egui
  module Ecss
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
    # plus element overrides (`Id` → `ElementEntry`). Built by
    # `#record_*` edits or `.parse`; written by `#to_s`.
    class Doc
      def initialize
        @classes = {} of String => StyleClass
        @elements = {} of UInt64 => ElementEntry
      end

      getter classes : Hash(String, StyleClass)
      getter elements : Hash(UInt64, ElementEntry)

      def empty? : Bool
        @classes.all? { |_p, c| c.vars.empty? && c.states.all? { |_s, b| b.empty? } } &&
          @elements.all? { |_i, e| e.empty? }
      end

      # "button:hover" → {"button", "hover"}; "button" → {"button", nil}.
      def self.split_selector(selector : String) : {String, String?}
        if (i = selector.rindex(':'))
          {selector[0...i], selector[(i + 1)..]}
        else
          {selector, nil}
        end
      end

      # Merge one key into a class rule (creating the class on first
      # touch, like `StyleSheet#rule`).
      def set_class(path : String, state : String?, key : String,
                    value : StyleValue) : Nil
        cls = (@classes[path] ||= StyleClass.new(path))
        state ? cls.set(state, StyleVars{key => value}) : cls.set(StyleVars{key => value})
      end

      # Remove one key; true when the document changed. Drops the rule
      # entirely once every bag is empty, so the file never accumulates
      # `button { }` husks.
      def unset_class(path : String, state : String?, key : String) : Bool
        return false unless (cls = @classes[path]?)
        if state
          cls.states[state]?.try &.delete(key)
          cls.states.delete(state) if cls.states[state]?.try &.empty?
        else
          cls.vars.delete(key)
        end
        if cls.vars.empty? && cls.states.all? { |_st, bag| bag.empty? }
          @classes.delete(path)
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
        io << "/* ecss v1 — egui.cr style diff (written by the inspector's save button) */\n"
        @classes.keys.sort.each do |path|
          cls = @classes[path]
          write_rule(io, path, cls.vars)
          cls.states.keys.sort.each do |state|
            write_rule(io, "#{path}:#{state}", cls.states[state])
          end
        end
        @elements.values.sort_by(&.target).each do |entry|
          write_rule(io, "##{entry.target}", entry.vars) unless entry.vars.empty?
          entry.states.keys.sort.each do |state|
            write_rule(io, "##{entry.target}:#{state}", entry.states[state])
          end
        end
      end

      private def write_rule(io : IO, selector : String, vars : StyleVars) : Nil
        return if vars.empty?
        io << '\n' << selector << " {\n"
        vars.keys.sort.each do |key|
          io << "  " << key << ": " << Doc.format_value(vars[key]) << ";\n"
        end
        io << "}\n"
      end

      # The value spelling: colors as `#rrggbbaa` (the same lowercase
      # hex `StyleSheet#dump` uses), whole numbers without the `.0`.
      def self.format_value(v : StyleValue) : String
        case v
        when Color32
          sprintf("#%02x%02x%02x%02x", v.r, v.g, v.b, v.a)
        when Float64
          v % 1 == 0 ? v.to_i64.to_s : v.to_s
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
      def self.parse(text : String) : Doc
        doc = Doc.new
        pos = 0
        size = text.size
        loop do
          pos = skip_blank(text, pos)
          break if pos >= size
          if text[pos] == '}'
            pos += 1
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
          parse_rule(doc, selector, text[(brace + 1)...close])
          break if close >= size
          pos = close + 1
        end
        doc
      end

      private def self.parse_rule(doc : Doc, selector : String,
                                  body : String) : Nil
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
            doc.set_class(target, state, key, value)
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
          if (value = parse_value(part[(ci + 1)..].strip))
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
        else
          if (n = s.to_f64?)
            n
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
      @applied_class : Array({String, String?, String, StyleValue?})
      @applied_element : Array({Id, String?, String})

      def self.enable(ctx : Context, app_id : String) : Session
        # A FLAT file next to the binary — no per-app subdirectory: the
        # natural dir name (<bin_dir>/<app_id>) collides with the app's
        # own binary (bin/notepad is a FILE), so the id rides in the
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
        @applied_class = [] of {String, String?, String, StyleValue?}
        @applied_element = [] of {Id, String?, String}
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
      def record_class(selector : String, key : String,
                       value : StyleValue) : Nil
        path, state = Doc.split_selector(selector)
        @doc.set_class(path, state, key, value)
        journal_class(path, state, key)
        @ctx.stylesheet.rule(selector, StyleVars{key => value})
        @dirty = true
      end

      # One class-rule key removal; a no-op on the file when the key
      # was never part of the diff (un-setting an app-defined rule).
      def unset_class(selector : String, key : String) : Nil
        path, state = Doc.split_selector(selector)
        if (i = journal_class_index(path, state, key))
          restore_class(@applied_class.delete_at(i))
        else
          @ctx.stylesheet.unset(selector, key)
        end
        @dirty = true if @doc.unset_class(path, state, key)
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
        @doc.elements.each_value do |entry|
          apply_element(entry.id, nil, entry.vars)
          entry.states.each do |state, vars|
            apply_element(entry.id, state, vars)
          end
        end
      end

      private def apply_class(path : String, state : String?,
                              vars : StyleVars) : Nil
        return if vars.empty?
        selector = state ? "#{path}:#{state}" : path
        vars.each do |key, value|
          journal_class(path, state, key)
          @ctx.stylesheet.rule(selector, StyleVars{key => value})
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
      private def journal_class(path : String, state : String?,
                                key : String) : Nil
        return if journal_class_index(path, state, key)
        prev = @ctx.stylesheet.resolve(path, state)[key]?
        @applied_class << {path, state, key, prev}
      end

      private def journal_class_index(path : String, state : String?,
                                      key : String) : Int32?
        @applied_class.index do |t|
          t[0] == path && t[1] == state && t[2] == key
        end
      end

      # Put one journaled key back: the captured pre-session value when
      # there was one (a theme/app rule), a plain unset otherwise.
      private def restore_class(entry : {String, String?, String, StyleValue?}) : Nil
        path, state, key, prev = entry
        selector = state ? "#{path}:#{state}" : path
        if prev
          @ctx.stylesheet.rule(selector, StyleVars{key => prev})
        else
          @ctx.stylesheet.unset(selector, key)
        end
      end

      private def unapply : Nil
        @applied_class.each { |entry| restore_class(entry) }
        @applied_element.each do |id, state, key|
          @ctx.clear_id_style(id, key, state)
        end
        @applied_class.clear
        @applied_element.clear
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
