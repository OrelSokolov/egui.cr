# vue2velvet — the Vue SFC → egui.cr port tool (plans/vue2velvet.md).
#
# The 1:1 half of a Vue port: `<template>` → `.exml`, `<style>` →
# `.ecss`. The `<script>` half is NEVER translated — by design, not
# by omission: the logic half of a converted component is a Crystal
# `Egui::Exml::Component` class (exml.cr, §components) written by
# hand or by an AI assistant, guided by the conversion REPORT, which
# lists every slot, list and action the markup expects the component
# to publish (`rt.strings`/`rt.floats`, `rt.rows`, `rt.actions`).
#
# The conversion is mechanical and additive on both sides:
#   * Vue directive spellings pass through VERBATIM — exml parses
#     them as aliases and desugars to the canonical tree at parse
#     time (plans/vue-aliases.md), so `v-if`/`v-for`/`@click`/`:key`
#     in the output are already legal exml;
#   * `{{ x }}` interpolations rewrite to the exml `{x}` spelling;
#   * HTML element names map onto the exml vocabulary (TAG_MAP
#     below); anything without an engine element stays a Custom
#     node, named in the report — the honest "no half-properties"
#     answer, not a silently misrendered guess;
#   * element TEXT content lifts into `text="…"` attributes — the
#     exml parser reads attributes, not text nodes (`<p>{{x}}</p>` →
#     `<label text="{x}"/>`); `class="a b"` chains to the dotted
#     ECSS class path `"a.b"`.
#
# The template grammar accepted here is the same subset exml's own
# parser tolerates: elements, double-quoted attributes, comments,
# self-closing and void tags, lenient close-tag matching.

require "../egui"

module Egui
  module Vue2Velvet
    class Result
      getter base : String
      getter exml : String
      getter ecss : String?
      getter report : Array(String)
      getter nodes : Array(Exml::Node)

      def initialize(@base, @exml, @ecss, @report, @nodes)
      end

      # A source without a <template> block has nothing to convert.
      def ok? : Bool
        !report.any?(&.starts_with?("no <template>"))
      end

      # Writes `<base>.exml` (and `<base>.ecss` when styles exist)
      # into `dir` (created when missing); returns the paths written.
      def write(dir : String) : Array(String)
        FileUtils.mkdir_p(dir)
        written = [File.join(dir, "#{base}.exml")]
        File.write(written[0], exml + "\n")
        if ecss
          written << File.join(dir, "#{base}.ecss")
          File.write(written.last, ecss.not_nil! + "\n")
        end
        written
      end
    end

    # One parsed element: raw name + ordered attrs + kids (child
    # elements interleaved with text runs). Names keep their case —
    # PascalCase marks a Vue component, everything else downcases.
    class Elem
      property name : String
      property attrs : Array(Tuple(String, String))
      property kids : Array(Elem | String)

      def initialize(@name, @attrs = [] of Tuple(String, String))
        @kids = [] of Elem | String
      end
    end

    # HTML elements with a 1:1 exml vocabulary counterpart. Names
    # without an entry (ul/li, a, img, table, …) stay Custom nodes
    # and land in the report — mapping them is the AI port's job.
    TAG_MAP = {
      "div" => "box", "section" => "box", "article" => "box",
      "aside" => "box", "header" => "box", "footer" => "box",
      "nav" => "box",
      "h1" => "heading", "h2" => "heading", "h3" => "heading",
      "h4" => "heading", "h5" => "heading", "h6" => "heading",
      "p" => "label", "span" => "label", "strong" => "label",
      "em" => "label", "small" => "label", "code" => "label",
      "label" => "label", "button" => "button",
      "textarea" => "textarea", "select" => "combo",
      "hr" => "separator", "progress" => "progress",
    } of String => String

    # Mapped kinds whose element text becomes `text="…"`; the exml
    # side of these widgets reads a text attribute, not children.
    TEXT_KINDS = {"heading", "label", "button"}

    # HTML void elements — closed without a `</…>`.
    VOID = {"br", "hr", "img", "input", "meta", "link"}

    # Elements already named canonically in the exml vocabulary —
    # pass through unmolested (built from KIND_BY_NAME so it never
    # drifts).
    NATIVE = Exml::KIND_BY_NAME.keys.to_set

    # Conversion bookkeeping — everything the report says.
    class State
      property mapped = [] of String
      property unmapped = Set(String).new
      property components = Set(String).new
      property mixed = Set(String).new
      property bare_text = 0
      property input_types = Set(String).new
      property selects = 0
      property interpolations = 0
    end

    record Block, attrs : String, body : String

    # ── SFC split ─────────────────────────────────────────────────────

    # The '>' closing a tag, skipping quoted attribute values (an
    # attribute may legally hold '>', `v-if="count > 0"`).
    private def self.tag_end(s : String, lt : Int32) : Int32?
      in_q = false
      i = lt + 1
      while i < s.size
        c = s.char_at(i)
        if in_q
          in_q = false if c == '"'
        elsif c == '"'
          in_q = true
        elsif c == '>'
          return i
        end
        i += 1
      end
      nil
    end

    # The single top-level `<tag …>…</tag>` block: FIRST open, LAST
    # close — a template may nest `<template>` elements inside, and
    # the outer close is the file's last one.
    private def self.top_block(source : String, tag : String) : Block?
      open_at = source.index(/<#{tag}[\s>]/) || return nil
      gt = tag_end(source, open_at) || return nil
      attrs = source[(open_at + 1 + tag.size)...gt].strip
      close = source.rindex("</#{tag}>") || return nil
      return nil unless close > gt
      Block.new(attrs, source[(gt + 1)...close])
    end

    # Every top-level `<tag>` block (styles may repeat).
    private def self.all_blocks(source : String, tag : String) : Array(Block)
      out = [] of Block
      pos = 0
      while (open_at = source.index(/<#{tag}[\s>]/, pos))
        gt = tag_end(source, open_at)
        break unless gt
        close = source.index("</#{tag}>", gt)
        break unless close
        attrs = source[(open_at + 1 + tag.size)...gt].strip
        out << Block.new(attrs, source[(gt + 1)...close])
        pos = close + tag.size + 3
      end
      out
    end

    # ── template parse (elements, attrs, text runs, comments) ────────

    private def self.parse_attrs(s : String) : Array(Tuple(String, String))
      attrs = [] of Tuple(String, String)
      s.scan(/([^\s=\/>"']+)\s*=\s*"([^"]*)"/) do |m|
        attrs << {m[1].downcase, unescape(m[2])}
      end
      attrs
    end

    private def self.unescape(s : String) : String
      s.gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", "\"")
        .gsub("&apos;", "'").gsub("&amp;", "&")
    end

    private def self.escape_attr(s : String) : String
      s.gsub('&', "&amp;").gsub('"', "&quot;")
        .gsub('<', "&lt;").gsub('>', "&gt;")
    end

    private def self.parse_template(text : String) : Array(Elem | String)
      root = Elem.new("")
      stack = [root]
      i = 0
      while i < text.size
        lt = text.index('<', i)
        unless lt
          stack.last.kids << text[i..]
          break
        end
        stack.last.kids << text[i...lt] if lt > i
        i = lt

        if text[lt, 4] == "<!--"
          i = (text.index("-->", lt + 4) || text.size - 3) + 3
          next
        end
        gt = tag_end(text, lt) || break
        inner = text[(lt + 1)...gt]
        i = gt + 1
        next if inner.empty?

        if inner.starts_with?('/')
          name = inner[1..].strip.downcase
          # pop to the matching open (tolerating skipped closes —
          # elems link into their parent's kids when opened, so a
          # close only pops); a stray close with no match is ignored
          if (idx = stack.rindex { |e| e.name == name }) && idx > 0
            while stack.size > idx
              stack.pop
            end
          end
        else
          self_close = inner.ends_with?('/')
          inner = inner.rchop.strip if self_close
          parts = inner.split(/\s+/, 2)
          elem = Elem.new(parts[0], parse_attrs(parts[1]? || ""))
          stack.last.kids << elem
          stack << elem unless self_close || VOID.includes?(parts[0].downcase)
        end
      end
      root.kids
    end

    # `{{ x }}` → `{x}` (attr values and text runs alike). NOTE:
    # Crystal's gsub block yields the matched STRING, not MatchData —
    # the backreference form is used instead.
    private def self.interp(s : String, st : State) : String
      st.interpolations += s.scan(/\{\{\s*[^{}]+?\s*\}\}/).size
      s.gsub(/\{\{\s*([^{}]+?)\s*\}\}/, "{\\1}")
    end

    # ── serialize to exml ─────────────────────────────────────────────

    # Interp every text run ONCE (interp counts occurrences — calling
    # it twice would double-count). Elems pass through.
    private def self.normalize(kids : Array(Elem | String),
                               st : State) : Array(Elem | String)
      kids.map { |k| k.is_a?(String) ? interp(k, st) : k }
    end

    # Writes normalized kids (strings already interpolated): blank
    # runs write nothing, a text run becomes a <label>.
    private def self.write_kids(kids : Array(Elem | String), st : State,
                                io : IO, ind : String) : Nil
      kids.each do |kid|
        if kid.is_a?(String)
          t = kid.gsub(/\s+/, " ").strip
          next if t.empty?
          st.bare_text += 1
          io << ind << %(<label text=") << escape_attr(t) << %("/>) << '\n'
        else
          serialize_elem(kid, st, io, ind)
        end
      end
    end

    private def self.serialize_elem(elem : Elem, st : State, io : IO,
                                    ind : String) : Nil
      return serialize_select(elem, st, io, ind) if elem.name.downcase == "select"

      name, attrs = map_elem(elem, st)
      kids = [] of Elem | String

      if TEXT_KINDS.includes?(name)
        texts = [] of String
        elem.kids.each do |kid|
          if kid.is_a?(String)
            t = interp(kid, st).gsub(/\s+/, " ").strip
            texts << t unless t.empty?
          else
            kids << kid
          end
        end
        if kids.empty?
          # pure text content → the text= attribute
          attrs << {"text", texts.join(" ")} unless texts.empty? ||
                                                      attrs.any? { |k, _| k == "text" }
        elsif !texts.empty?
          # mixed content: exml text widgets hold no children — the
          # elements survive, the dropped text runs land in the report
          st.mixed << elem.name
        end
      else
        elem.kids.each do |kid|
          kids << (kid.is_a?(String) ? interp(kid, st) : kid)
        end
      end

      open_tag = ind + "<" + name
      attrs.each { |k, v| open_tag += %( #{k}="#{escape_attr(v)}") }
      has_content = kids.any? { |k| k.is_a?(Elem) || !k.as(String).strip.empty? }
      if has_content
        io << open_tag << ">" << '\n'
        write_kids(kids, st, io, ind + "  ")
        io << ind << "</" << name << ">" << '\n'
      else
        io << open_tag << "/>" << '\n'
      end
    end

    # <select v-model="pick"><option>A</option></select> →
    # <combo v-model="pick" options="A"/> — the exml combo takes its
    # options as an attribute. An option whose value attr differs
    # from its text keeps the TEXT (labels are what the combo shows);
    # value-keyed selects are out of the 1:1 subset.
    private def self.serialize_select(elem : Elem, st : State, io : IO,
                                      ind : String) : Nil
      st.selects += 1
      name, attrs = map_elem(elem, st)
      opts = [] of String
      rest = [] of Elem | String
      elem.kids.each do |kid|
        if kid.is_a?(Elem) && kid.name.downcase == "option"
          text = kid.kids.select(String).map(&.strip).reject(&.empty?).join(" ")
          opts << (text.empty? ? "" : interp(text, st))
        elsif kid.is_a?(String) && kid.strip.empty?
          next # whitespace between options writes nothing
        else
          rest << kid
        end
      end
      attrs << {"options", opts.reject(&.empty?).join(",")} unless opts.empty?
      open_tag = ind + "<" + name
      attrs.each { |k, v| open_tag += %( #{k}="#{escape_attr(v)}") }
      has_content = rest.any? { |k| k.is_a?(Elem) || !k.as(String).strip.empty? }
      if has_content
        io << open_tag << ">" << '\n'
        write_kids(normalize(rest, st), st, io, ind + "  ")
        io << ind << "</" << name << ">" << '\n'
      else
        io << open_tag << "/>" << '\n'
      end
    end

    # Element name mapping + attr fixups (interpolation into values,
    # `class="a b"` → the dotted `"a.b"` path, input type dispatch).
    private def self.map_elem(elem : Elem,
                              st : State) : Tuple(String, Array(Tuple(String, String)))
      low = elem.name.downcase
      attrs = elem.attrs.map { |k, v| {k, interp(v, st)} }

      name =
        if low == "input"
          type = attrs.find { |k, _| k == "type" }.try &.[1]
          attrs = attrs.reject { |k, _| k == "type" }
          case type
          when "range"   then st.mapped << "input[range]→slider"; "slider"
          when "checkbox" then st.mapped << "input[checkbox]→checkbox"; "checkbox"
          else
            st.input_types << type if type && type != "text"
            "input"
          end
        elsif (m = TAG_MAP[low]?)
          st.mapped << "#{low}→#{m}" unless m == low
          m
        elsif NATIVE.includes?(low)
          low
        elsif elem.name[0].uppercase?
          st.components << elem.name
          low
        else
          st.unmapped << low
          low
        end

      attrs = attrs.map do |k, v|
        {k, k == "class" && v.includes?(' ') ? v.split(/\s+/).join('.') : v}
      end
      if name == "progress" && !attrs.any? { |k, _| k == "v-model" || k == "bind" }
        st.mapped << "progress (no v-model — add bind= holding a 0..1 slot)"
      end
      {name, attrs}
    end

    # ── convert ───────────────────────────────────────────────────────

    def self.convert(source : String, base : String = "component") : Result
      st = State.new
      report = [] of String

      tpl = top_block(source, "template")
      unless tpl
        report << "no <template> block — nothing to convert"
        return Result.new(base, "", nil, report, [] of Exml::Node)
      end

      io = IO::Memory.new
      write_kids(normalize(parse_template(tpl.body), st), st, io, "")
      exml = io.to_s.strip

      styles = all_blocks(source, "style")
      ecss = styles.empty? ? nil : styles.map(&.body).join("\n").strip

      # Verify: the output must parse as a legal fragment. The alias
      # desugar runs here too — v-for/@click/:key warnings (a JS
      # expression value, say) surface in the report, not at render.
      nodes = Exml.parse_fragment(exml)

      report << "template: #{st.interpolations} interpolation(s) rewritten {{ x }} → {x}"
      unless st.mapped.empty?
        report << "tags mapped: #{st.mapped.uniq.join(", ")}"
      end
      unless st.unmapped.empty?
        report << "unmapped HTML (Custom nodes — register Renderer#on handlers" \
                  " or rewrite): #{st.unmapped.to_a.sort.join(", ")}"
      end
      unless st.components.empty?
        report << "Vue components (port as Egui::Exml::Component classes): " \
                  "#{st.components.to_a.sort.join(", ")}"
      end
      unless st.mixed.empty?
        report << "mixed content (elements kept, loose text runs dropped): " \
                  "#{st.mixed.to_a.sort.join(", ")}"
      end
      report << "bare text runs wrapped into <label>: #{st.bare_text}" if st.bare_text > 0
      unless st.input_types.empty?
        report << "input types kept as the plain <input> kind: " \
                  "#{st.input_types.to_a.sort.join(", ")}"
      end

      if (script = top_block(source, "script"))
        report << "script: skipped (#{script.body.count('\n')} lines) — write the" \
                  " Crystal half: class #{camel(base)} < Egui::Exml::Component;" \
                  %( exml "#{base}.exml")
      else
        report << "script: none (static markup)"
      end

      if ecss
        scoped = styles.count { |b| b.attrs.includes?("scoped") }
        langs = styles.map(&.attrs[/lang="(\w+)"/, 1]?).compact.reject { |l| l == "css" }
        note = "scoped ignored on #{scoped} block(s) — ECSS scopes by dotted" \
               " class path, not by attribute" if scoped > 0
        note = "#{langs.uniq.join("/")} is not CSS — copied verbatim; ECSS will" \
               " not parse it" unless langs.empty?
        report << "style: #{styles.size} block(s) → #{base}.ecss#{note ? " (#{note})" : ""}"
      end

      add_port_hints(report, nodes, base)
      Exml.warnings.each { |w| report << "exml: #{w}" }
      report << "exml parse: OK, #{nodes.size} top-level node(s)"

      Result.new(base, exml, ecss, report, nodes)
    end

    # What the markup expects the Crystal half to publish — the AI
    # port's checklist, derived from the converted tree. Row fields
    # (`{item.name}`) and index aliases (`{i}`, `{_i}`) are covered
    # by the rt.rows hint and stay out of the slot list.
    private def self.add_port_hints(report : Array(String), nodes : Array(Exml::Node),
                                    base : String) : Nil
      slots = Set(String).new
      rows = Set(String).new
      actions = Set(String).new
      conds = Set(String).new
      row_scoped = Set(String).new # "#{for}." prefixes + index aliases
      collect_hints(nodes, slots, rows, actions, conds, row_scoped)
      slots.reject! { |s| s == "_i" || row_scoped.any? { |p| s == p.rchop('.') || s.starts_with?(p) } }
      report << "slots to publish (rt.strings/rt.floats): #{slots.to_a.sort.join(", ")}" unless slots.empty?
      report << "lists to publish (rt.rows): #{rows.to_a.sort.join(", ")}" unless rows.empty?
      report << "actions to register (rt.actions): #{actions.to_a.sort.join(", ")}" unless actions.empty?
      report << "conditions (if=/v-if slots): #{conds.to_a.sort.join(", ")}" unless conds.empty?
    end

    private def self.collect_hints(nodes : Array(Exml::Node), slots : Set(String),
                                   rows : Set(String), actions : Set(String),
                                   conds : Set(String),
                                   row_scoped : Set(String)) : Nil
      nodes.each do |n|
        conds << n.if_cond.not_nil! if n.if_cond
        conds << n.unless_cond.not_nil! if n.unless_cond
        if n.repeat_in
          rows << n.repeat_in.not_nil!
          row_scoped << "#{n.repeat_for || "item"}."
          row_scoped << n.repeat_index_alias.not_nil! if n.repeat_index_alias
        end
        n.attrs.each do |k, v|
          case k
          when "bind" then slots << v
          when "on_click", "on_change", "on_button" then actions << v
          end
          v.scan(/\{([^{}]+)\}/) { |m| slots << m[1] }
        end
        collect_hints(n.children, slots, rows, actions, conds, row_scoped)
      end
    end

    private def self.camel(base : String) : String
      base.split(/[-_.]/).map(&.capitalize).join
    end
  end
end
