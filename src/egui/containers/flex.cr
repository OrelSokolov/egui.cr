# CSS flexbox for egui.cr — the real algorithm (line breaking →
# resolve flexible lengths → cross-axis distribution), all modes:
#
#   flex-direction: row | row-reverse | column | column-reverse
#   flex-wrap:      nowrap | wrap | wrap-reverse
#   justify-content:flex-start | center | flex-end | space-between |
#                  space-around | space-evenly
#   align-items:    stretch | flex-start | center | flex-end | baseline
#   align-content:  stretch | flex-start | center | flex-end |
#                  space-between | space-around | space-evenly
#   flex-grow / flex-shrink / flex-basis (px or %), order, gap
#
# Two-pass layout: immediate mode lays out as it runs, but flex needs
# every child's natural size before placing anything. Pass 1 (the
# measure pass, `Context#measure`) runs each child block in a cell of
# the container's width — paint discarded, `Context#interact`
# returning dead verdicts — so response-gated callbacks fire exactly
# once (pass 2). Geometry is therefore EXACT FROM THE FIRST FRAME,
# with no Grid-style one-frame convergence; the contract is that a
# child block must be idempotent (widget state writes are — same id,
# same inputs, same values), and side effects not gated on a Response
# must guard with `ui.measuring?`.
#
#   ui.flex(justify: :space_between) do |f|
#     f.child { |ui| ui.label("left") }
#     f.child(grow: 1) { |ui| ui.text_field(...) }
#   end
#
# Deviations from the CSS spec (documented in SPEC.md):
#   * `align-items: baseline` is approximated as bottom-alignment
#     (every label-like widget already shares the row center line, so
#     the common case renders correctly);
#   * shrinking floors at 0, not min-content (no min-content pass);
#   * an `auto`-basis child never grows past its natural size (CSS
#     caps it at max-content — here natural == max-content by
#     definition of the measure cell);
#   * percentages resolve only against a definite axis (in flow the
#     width is definite, the height is not — `box(height: …)` or an
#     absolute top+bottom stretch makes it definite).

module Egui
  class Flex
    # One flex item: the child's placement inputs plus what the two
    # passes fill in (`natural` from measure, `base`/`slot` from the
    # distribution).
    class Child
      property grow : Float64
      property shrink : Float64
      # `flex-basis`: a px number, a "%"-string (definite main axis
      # only) or nil (`auto` — the measured natural main size).
      property basis : Float64 | String | Nil
      property order : Int32
      property align_self : Symbol?
      getter block : (Ui ->)?
      getter widget : Widget?
      property natural : Vec2 = Vec2.zero
      property base : Float64 = 0.0
      property slot : Rect = Rect.zero

      def initialize(@grow : Float64 = 0.0, @shrink : Float64 = 1.0,
                     @basis : Float64 | String | Nil = nil,
                     @order : Int32 = 0, @align_self : Symbol? = nil,
                     @block : (Ui ->)? = nil, @widget : Widget? = nil)
      end
    end

    # One wrap line: the items packed on it, their resolved main
    # sizes and the line's cross extent.
    class Line
      property items : Array(Child) = [] of Child
      property sizes : Array(Float64) = [] of Float64
      property cross : Float64 = 0.0
    end

    getter flex_id : Id

    # Container properties — CSS spellings mapped to Crystal symbols
    # by `Flex.parse_*` (also what Ui#flex uses for the ECSS cascade).
    property direction : Symbol = :row
    property wrap : Symbol = :nowrap
    property justify : Symbol = :start
    property align : Symbol = :stretch
    property align_content : Symbol = :stretch
    # gap.x = main-axis gap (row-gap), gap.y = cross-axis gap
    # (column-gap) — per CSS, each applies along its axis whatever
    # the direction is.
    property gap : Vec2 = Vec2.zero

    @children : Array(Child) = [] of Child

    EPS = 0.01

    def initialize(id : String | Id = "flex")
      @flex_id = id.is_a?(Id) ? id : Id.from("flex/#{id}")
    end

    # --- child declaration ----------------------------------------------

    def child(grow : Float64 = 0.0, shrink : Float64 = 1.0,
              basis : Float64 | String | Symbol? = nil,
              order : Int32 = 0, align_self : Symbol? = nil,
              &block : Ui ->) : Nil
      @children << Child.new(grow, shrink,
        basis.is_a?(Symbol) ? nil : basis, order, align_self, block)
    end

    # A ready `Widget` (the `Widget#ui` protocol) as a flex item.
    def add(widget : Widget, grow : Float64 = 0.0, shrink : Float64 = 1.0,
            basis : Float64 | String | Symbol? = nil, order : Int32 = 0,
            align_self : Symbol? = nil) : Nil
      @children << Child.new(grow, shrink,
        basis.is_a?(Symbol) ? nil : basis, order, align_self, nil, widget)
    end

    # --- the two passes ---------------------------------------------------

    # Lay the children out inside `ui` (the chrome-less content region
    # `Ui#flex` gets from `#box`, or any region with a definite width).
    # Returns the content bounding rect; `ui.min_rect` grows to cover
    # every child (overflowing children included — CSS `overflow:
    # visible`).
    #
    # Nesting cost: a flex inside an ANCESTOR's measure pass runs in
    # measure MODE — one pass over its children (their real pass
    # would be discarded paint anyway), reporting its natural content
    # extent upward; a per-frame memo (`Context#flex_measure`) reuses
    # the measured naturals when the real pass lands on the same
    # available width. Without these, each nesting level doubled the
    # subtree runs (2^depth); with them the cost is linear in depth.
    def render(ui : Ui) : Rect
      return ui.min_rect if @children.empty?

      row = @direction == :row || @direction == :row_reverse
      rev_main = @direction == :row_reverse || @direction == :column_reverse
      wrapped = @wrap == :wrap || @wrap == :wrap_reverse
      wrap_reverse = @wrap == :wrap_reverse

      # Definite container axes: the flow width always is; the height
      # only when the box got an explicit one (the 1e6 layout region
      # marks content-driven, see Ui#box).
      height_definite = ui.max_rect.height < 1e5
      main_size = row ? ui.max_rect.width
        : (height_definite ? ui.max_rect.height : 0.0)
      cross_size = row ? (height_definite ? ui.max_rect.height : 0.0)
        : ui.max_rect.width

      ordered = @children.each_with_index
        .to_a.sort_by { |(child, i)| {child.order, i} }
        .map(&.first)

      ctx = ui.ctx
      measuring = ctx.measuring?

      # --- pass 1: measure (paint discarded, interaction dead) ----------
      # The per-frame memo short-circuits the child runs when this
      # flex already measured at (nearly) the same available width —
      # the nested case: measured inside the ancestor's measure pass,
      # reused by the real pass.
      avail = ui.max_rect.width
      Egui::Bench.count("flex.render")
      cell_ids = nil
      if (memo = ctx.flex_measure(@flex_id, avail)) &&
         (memo.avail - avail).abs < 0.5 &&
         memo.naturals.size == ordered.size
        Egui::Bench.count("flex.memo.hit")
        ordered.each_with_index { |child, i| child.natural = memo.naturals[i] }
        cell_ids = memo.ids
      else
        Egui::Bench.count("flex.memo.miss")
        naturals = [] of Vec2
        ids = [] of Id
        Egui::Bench.span("flex.measure") do
        ordered.each_with_index do |child, i|
          cid = @flex_id.child(i.to_u64 + 1)
          ids << cid
          cell = ui.child_ui(
            Rect.from_min_size(ui.max_rect.min,
              Vec2.new(ui.max_rect.width, 1e6)),
            id: cid)
          if measuring
            # Already inside the ancestor's measure bracket: the paint
            # is truncated by it and interact is dead — run directly.
            run_child(child, cell)
          else
            ctx.measure { run_child(child, cell) }
          end
          child.natural = cell.min_rect.size
          naturals << child.natural
        end
        end
        cell_ids = ids
        ctx.set_flex_measure(@flex_id, avail,
          Context::FlexMeasure.new(avail, naturals, ids))
      end

      # --- distribution ---------------------------------------------------
      # Hypothetical main size (flex-basis, % against the definite
      # main axis, else the measured natural size).
      ordered.each do |child|
        child.base = case (b = child.basis)
                     when Float64 then b
                     when String  then percent_of(b, main_size) || natural_main(child, row)
                     else              natural_main(child, row)
                     end
      end

      lines = Egui::Bench.span("flex.distribute") { break_lines(ordered, main_size) }
      Egui::Bench.span("flex.distribute") do
      lines.each do |line|
        resolve_main(line, main_size, row)
        crosses = line.items.map { |c| row ? c.natural.y : c.natural.x }
        line.cross = crosses.max? || 0.0
      end
      # A single-line (nowrap) container with a definite cross size
      # sizes its line to the CONTAINER, not the tallest child's
      # natural (CSS §9.4: the line fills the flex container under
      # `align-content: stretch`, the default). Taller children
      # overflow and are clipped — they must not enlarge the siblings'
      # cells (a sidebar list would blow up the center panel's slot).
      if !wrapped && cross_size > EPS && @align_content == :stretch
        lines.each { |l| l.cross = cross_size }
      end
      end
      line_crosses = Egui::Bench.span("flex.distribute") { stretch_lines(lines, cross_size) } if wrapped

      Egui::Bench.span("flex.place") do
        place(lines, ui, row, rev_main, wrap_reverse,
          main_size, cross_size, line_crosses)
      end

      # --- measure mode: single pass, no real layout ---------------------
      # This flex renders inside an ANCESTOR's measure pass — the real
      # child pass would only produce discarded paint. Report the
      # natural content extent (what the ancestor's distribution needs)
      # and return: the real layout happens in the ancestor's real
      # pass, reusing the memo above when widths match.
      if measuring
        main_extent = lines.map do |l|
          l.sizes.sum + @gap.x * {l.sizes.size - 1, 0}.max
        end.max? || 0.0
        cross_extent = lines.sum(&.cross) + @gap.y * (lines.size - 1)
        size = row ? Vec2.new(main_extent, cross_extent)
          : Vec2.new(cross_extent, main_extent)
        ui.min_rect = ui.min_rect.union(
          Rect.from_min_size(ui.max_rect.min, size))
        ui.cursor = Pos2.new(ui.max_rect.min.x,
          ui.min_rect.bottom + ui.style.spacing.item_spacing.y)
        return ui.min_rect
      end

      # --- pass 2: the real layout ----------------------------------------
      # A paint-cache miss inside the pass means some child's CONTENT
      # changed — its natural size may be stale in the memo; drop it so
      # the next frame re-measures (hover transitions miss too — a
      # single re-measure frame, then the memo is stored again).
      miss0 = ctx.paint_cache.real_misses
      ids = cell_ids
      Egui::Bench.span("flex.real") do
        ordered.each_with_index do |child, i|
          cell = ui.child_ui(child.slot,
            id: ids ? ids.not_nil![i] : @flex_id.child(i.to_u64 + 1))
          ui.ctx.memory.use_id(cell.id)
          run_child(child, cell)
          ui.min_rect = ui.min_rect.union(cell.min_rect)
        end
      end
      ctx.drop_flex_measure(@flex_id, avail) if ctx.paint_cache.real_misses > miss0
      ui.cursor = Pos2.new(ui.max_rect.min.x,
        ui.min_rect.bottom + ui.style.spacing.item_spacing.y)
      ui.min_rect
    end

    private def run_child(child : Child, cell : Ui) : Nil
      if (block = child.block)
        block.call(cell)
      elsif (widget = child.widget)
        widget.ui(cell)
      end
    end

    private def natural_main(child : Child, row : Bool) : Float64
      row ? child.natural.x : child.natural.y
    end

    private def percent_of(s : String, whole : Float64) : Float64?
      return nil unless s.ends_with?('%')
      return nil unless whole > 0.0
      (pct = s[0...s.size - 1].to_f64?) ? pct / 100.0 * whole : nil
    end

    # --- line breaking (§3) / flexible lengths (§4) ----------------------

    private def break_lines(ordered : Array(Child),
                            main_size : Float64) : Array(Line)
      lines = [Line.new]
      single = @wrap == :nowrap
      ordered.each do |child|
        line = lines.last
        used = line.items.sum(&.base) + @gap.x * {line.items.size - 1, 0}.max
        if !single && !line.items.empty? && main_size > EPS &&
           used + @gap.x + child.base > main_size + EPS
          line = Line.new
          lines << line
        end
        line.items << child
      end
      lines
    end

    # Resolve each line's main sizes in place: grow distributes
    # positive free space (auto-basis children capped at their natural
    # size — they never grow past content), shrink takes negative free
    # space proportionally to `shrink × size` (floor 0). Leftover free
    # space stays for justify-content.
    private def resolve_main(line : Line, main_size : Float64, row : Bool) : Nil
      items = line.items
      sizes = items.map(&.base)
      gaps = @gap.x * {items.size - 1, 0}.max

      # An INDEFINITE main axis (a column flex in flow, no explicit
      # height — CSS `height: auto`): the container grows with its
      # content, there is no free space and no overflow — children
      # keep their natural sizes (no grow, no shrink).
      if main_size <= EPS
        line.sizes = sizes
        return
      end

      free = main_size - sizes.sum - gaps
      if free > EPS
        # grow, capped for auto-basis children at their natural main
        loop do
          free = main_size - sizes.sum - gaps
          break if free <= EPS
          cap_of = ->(i : Int32) do
            items[i].basis.nil? ? natural_main(items[i], row) : Float64::INFINITY
          end
          growers = items.each_index.select do |i|
            items[i].grow > 0.0 && sizes[i] < cap_of.call(i) - EPS
          end.to_a
          break if growers.empty?
          sum_grow = growers.sum { |i| items[i].grow }
          break if sum_grow <= 0.0
          moved = false
          growers.each do |i|
            take = {free * items[i].grow / sum_grow,
                    cap_of.call(i) - sizes[i]}.min
            if take > EPS
              sizes[i] += take
              moved = true
            end
          end
          break unless moved
        end
      elsif free < -EPS
        total = items.each_index.sum do |i|
          items[i].shrink > 0.0 ? items[i].shrink * sizes[i] : 0.0
        end
        if total > 0.0
          items.each_index do |i|
            next unless items[i].shrink > 0.0
            cut = -free * items[i].shrink * sizes[i] / total
            sizes[i] = {sizes[i] - cut, 0.0}.max
          end
        end
      end

      line.sizes = sizes
    end

    # `align-content: stretch` (wrap only, definite cross axis): grow
    # each line's cross extent onto the leftover. The space-* modes
    # are placement, not extent — they run in #place.
    private def stretch_lines(lines : Array(Line),
                              cross_size : Float64) : Array(Float64)?
      return nil unless lines.size > 1 && cross_size > EPS
      crosses = lines.map(&.cross)
      extra = cross_size - crosses.sum - @gap.y * (lines.size - 1)
      return nil if extra <= EPS
      return nil unless @align_content == :stretch
      crosses.map { |c| c + extra / lines.size }
    end

    # --- placement ---------------------------------------------------------

    # Compute every child's slot rect: line cross positions
    # (align-content / wrap-reverse), main offsets inside the line
    # (justify-content, direction reversed), child cross position
    # (align-items / align-self).
    private def place(lines : Array(Line), ui : Ui, row : Bool,
                      rev_main : Bool, wrap_reverse : Bool,
                      main_size : Float64, cross_size : Float64,
                      line_crosses : Array(Float64)?) : Nil
      crosses = line_crosses || lines.map(&.cross)
      gaps_cross = @gap.y * (lines.size - 1)
      extra_cross = cross_size > EPS ?
        {cross_size - crosses.sum - gaps_cross, 0.0}.max : 0.0
      cross_at = line_cross_positions(crosses, extra_cross)

      lines.each_with_index do |line, li|
        line.cross = crosses[li]
        sizes = line.sizes
        used = sizes.sum + @gap.x * {sizes.size - 1, 0}.max
        free = main_size > EPS ? main_size - used : 0.0
        offsets = justify_offsets(sizes.size, free)

        cross_pos = cross_at[li]
        # wrap-reverse mirrors the line stack on the cross axis.
        if wrap_reverse && cross_size > EPS
          cross_pos = cross_size - cross_pos - line.cross
        end

        # Accumulated main position on the logical axis (main-start).
        logical = 0.0
        line.items.each_with_index do |child, i|
          size_i = sizes[i]
          logical_pos = logical + offsets[i]
          # row-reverse / column-reverse mirror the logical axis.
          main_pos = rev_main && main_size > EPS ?
            main_size - logical_pos - size_i : logical_pos

          a = child.align_self || @align
          slot_cross, cross_off = cross_slot(child, a, line.cross, row)
          cell_cross_pos = cross_pos + cross_off

          child.slot = if row
            Rect.from_min_size(
              Pos2.new(ui.max_rect.min.x + main_pos,
                ui.max_rect.min.y + cell_cross_pos),
              Vec2.new(size_i, slot_cross))
          else
            Rect.from_min_size(
              Pos2.new(ui.max_rect.min.x + cell_cross_pos,
                ui.max_rect.min.y + main_pos),
              Vec2.new(slot_cross, size_i))
          end
          logical += size_i + @gap.x
        end
      end
    end

    # Line start offsets on the cross axis (align-content; `extra` is
    # the leftover after the lines' extents).
    private def line_cross_positions(crosses : Array(Float64),
                                     extra : Float64) : Array(Float64)
      pos = [] of Float64
      acc = 0.0
      count = crosses.size
      crosses.each_with_index do |c, i|
        offset = case @align_content
                 when :end           then extra
                 when :center        then extra / 2.0
                 when :space_between then count > 1 ? i * extra / (count - 1) : 0.0
                 when :space_around  then i * (extra / count) + extra / (2 * count)
                 when :space_evenly  then (i + 1) * extra / (count + 1)
                 else                     0.0 # :stretch, :start
                 end
        pos << acc + offset
        acc += c + @gap.y
      end
      pos
    end

    # Main-axis offsets inside a line (justify-content), one per item.
    private def justify_offsets(count : Int32, free : Float64) : Array(Float64)
      (0...count).map do |i|
        case @justify
        when :end           then free
        when :center        then free / 2.0
        when :space_between then count > 1 ? i * free / (count - 1) : 0.0
        when :space_around  then i * (free / count) + free / (2 * count)
        when :space_evenly  then (i + 1) * free / (count + 1)
        else                     0.0 # :start
        end
      end
    end

    # The child's cross extent and offset inside its line
    # (align-items / align-self). `stretch` gives the child the whole
    # line extent (the child decides whether to fill it); `baseline`
    # is approximated as bottom-alignment (SPEC.md).
    private def cross_slot(child : Child, a : Symbol, line_cross : Float64,
                           row : Bool) : Tuple(Float64, Float64)
      natural = row ? child.natural.y : child.natural.x
      case a
      when :stretch         then {line_cross, 0.0}
      when :center          then {natural, (line_cross - natural) / 2.0}
      when :end, :baseline  then {natural, line_cross - natural}
      else                       # :start
        {natural, 0.0}
      end
    end

    # --- CSS spellings (also used by Ui#flex for the ECSS cascade) -------

    def self.parse_direction(s : String?) : Symbol?
      case s
      when "row"            then :row
      when "row-reverse"    then :row_reverse
      when "column"         then :column
      when "column-reverse" then :column_reverse
      end
    end

    def self.parse_wrap(s : String?) : Symbol?
      case s
      when "nowrap"       then :nowrap
      when "wrap"         then :wrap
      when "wrap-reverse" then :wrap_reverse
      end
    end

    def self.parse_justify(s : String?) : Symbol?
      case s
      when "flex-start", "start"  then :start
      when "center"               then :center
      when "flex-end", "end"      then :end
      when "space-between"        then :space_between
      when "space-around"         then :space_around
      when "space-evenly"         then :space_evenly
      end
    end

    def self.parse_cross_align(s : String?) : Symbol?
      case s
      when "stretch"              then :stretch
      when "flex-start", "start"  then :start
      when "center"               then :center
      when "flex-end", "end"      then :end
      when "baseline"             then :baseline
      end
    end

    # align-content accepts both the cross-axis keywords and the
    # space-* distributions.
    def self.parse_align_content(s : String?) : Symbol?
      parse_cross_align(s) || parse_justify(s)
    end
  end
end
