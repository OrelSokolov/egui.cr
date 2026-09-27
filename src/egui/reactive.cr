# Reactive state layer (Vue/Solid-style) over the immediate-mode core.
#
#   class MyApp < Egui::App
#     reactive count = 0                          # Signal(Int32)
#     reactive speed : Float64 = 0.3              # explicit type form
#     computed(:doubled) { count * 2 }            # memoized derivation
#
#     def update(ctx)
#       count += 1 if ui.button("Inc").clicked?
#     end
#   end
#
# Design (see egui-reactive.md):
# - `Signal(T)` — a state cell. A real write (`==` comparison; reassign,
#   don't mutate in place) bumps the version and dirties dependents.
# - `computed(:name) { ... }` — a memoized derivation. Reads performed
#   while it computes register as dependencies; a write to any input
#   marks it dirty, cascading through dependent computeds. The block
#   re-runs only when a dirty result is actually read, and a recompute
#   that yields the old value does not propagate further.
# - The `reactive` macro generates plain-looking `count` / `count=`
#   (`count += 1` reads like an ordinary ivar assignment). The Context
#   link lives in the generated setter — instance-variable defaults
#   cannot see the instance, so the Signal itself stays context-free:
#   a real out-of-frame write (timers, fibers, dialog callbacks) calls
#   `request_repaint` and wakes the backend; inside a frame the driving
#   event already bought the settle repaints.
#
# Signals hold app state, not widget state — they live in the App and
# are never stored in Memory/IdTypeMap.

module Egui
  # A computed block that (transitively) reads itself.
  class RecursionError < Exception
  end

  # Shared reactive-node plumbing: a change version plus the set of
  # dependent nodes — both Signal and Computed act as dependency
  # sources (a computed may read another computed).
  abstract class ReactiveNode
    getter version : UInt64 = 0_u64
    @subs = [] of ReactiveNode

    def subscribe(node : ReactiveNode) : Nil
      @subs << node unless @subs.includes?(node)
    end

    def unsubscribe(node : ReactiveNode) : Nil
      @subs.delete(node)
    end

    protected def notify_subs : Nil
      @subs.dup.each(&.mark_dirty)
    end

    protected def bump_version : Nil
      @version &+= 1
    end

    # Signals are always fresh; the no-op keeps them valid members of
    # any subscriber list (only computeds go dirty).
    def mark_dirty : Nil
    end
  end

  # Dependency tracking: reads register with the computed currently
  # computing (top of the stack). Active only while a dirty computed
  # is re-evaluating — plain `update`-code reads track nothing.
  module ReactiveTracking
    @@stack = [] of ComputedBase

    def self.read(node : ReactiveNode) : Nil
      reader = @@stack.last?
      return unless reader
      node.subscribe(reader)
      reader.deps << node unless reader.deps.includes?(node)
    end

    def self.push(computed : ComputedBase) : Nil
      @@stack.push(computed)
    end

    def self.pop : Nil
      @@stack.pop
    end

    def self.computing?(computed : ComputedBase) : Bool
      @@stack.includes?(computed)
    end
  end

  class Signal(T) < ReactiveNode
    def initialize(@value : T)
    end

    def value : T
      ReactiveTracking.read(self)
      @value
    end

    def value=(new : T) : T
      return new if new == @value
      @value = new
      bump_version
      notify_subs
      new
    end
  end

  # Dirty/dependency bookkeeping shared by every computed flavor.
  class ComputedBase < ReactiveNode
    getter deps = [] of ReactiveNode
    @dirty = true

    def dirty? : Bool
      @dirty
    end

    def mark_dirty : Nil
      return if @dirty
      @dirty = true
      notify_subs
    end

    # Drop the previous run's edges before re-collecting them, so a
    # dependency that is no longer read stops receiving dirty marks.
    protected def reset_deps : Nil
      deps.each(&.unsubscribe(self))
      deps.clear
    end

    # The computed's value really changed: version bump + cascade.
    protected def commit : Nil
      bump_version
      notify_subs
    end
  end

  # Untyped computed cell — the bookkeeping half the `computed` macro
  # needs. The cached value lives in the macro-generated ivar (its
  # type is inferred from the inlined block body), so the cell only
  # tracks dirty state and read dependencies — no erased value copy,
  # no generic type to spell out at declaration time.
  class ComputedCell < ComputedBase
    @pushed = false

    # Recompute prologue: recursion check, drop the previous run's
    # edges, start tracking reads. Pairs with #settle (success) or
    # #unpush (the block raised).
    def begin_compute : Nil
      if ReactiveTracking.computing?(self)
        raise RecursionError.new(
          "computed reads itself (directly or through a dependency cycle)")
      end
      reset_deps
      ReactiveTracking.push(self)
      @pushed = true
    end

    # Recompute success epilogue: stop tracking, clear dirty. Whether
    # the value changed (and downstream should be notified) is the
    # caller's call — only it sees the typed old/new pair.
    def settle : Nil
      unpush
      @dirty = false
    end

    def unpush : Nil
      if @pushed
        ReactiveTracking.pop
        @pushed = false
      end
    end
  end

  # Standalone typed computed for programmatic use (spec/test code,
  # values stored outside the App): `c = Egui::Computed.new { a + b }`.
  class Computed(T) < ComputedBase
    def initialize(&@calculate : -> T)
    end

    @has_value = false
    @value = uninitialized T

    def value : T
      ReactiveTracking.read(self)
      if @dirty
        new_value = compute_inner
        @dirty = false
        if @has_value && new_value == @value
          # Recomputed to the old value: nothing downstream changed.
          return @value
        end
        @value = new_value
        @has_value = true
        commit
        return @value
      end
      @value
    end

    private def compute_inner : T
      if ReactiveTracking.computing?(self)
        raise RecursionError.new(
          "computed reads itself (directly or through a dependency cycle)")
      end
      reset_deps
      ReactiveTracking.push(self)
      @calculate.call
    ensure
      ReactiveTracking.pop
    end
  end

  # Class-body macros for reactive fields (included in `Egui::App`).
  module Reactive
    # `reactive count = 0` or `reactive speed : Float64 = 0.3` —
    # @count : Signal(Int32) plus a plain-looking getter/setter pair.
    # The ivar carries an explicit type argument: Crystal cannot infer
    # a generic's type argument from constructor arguments in an
    # instance-variable default, so the literal forms are mapped inline
    # above and everything else goes through the `name : Type =
    # default` form.
    macro reactive(decl)
      {% if decl.is_a?(TypeDeclaration) %}
        {% name = decl.var %}
        {% type = decl.type %}
        {% default = decl.value %}
        {% if default.is_a?(Nop) %}
          {% raise "reactive expects a default: `#{name} : #{type} = ...`" %}
        {% end %}
      {% elsif decl.is_a?(Assign) && decl.value.is_a?(NumberLiteral) %}
        {% name = decl.target %}
        {% default = decl.value %}
        {% if default.kind == :i8 %} {% type = Int8 %}
        {% elsif default.kind == :i16 %} {% type = Int16 %}
        {% elsif default.kind == :i32 %} {% type = Int32 %}
        {% elsif default.kind == :i64 %} {% type = Int64 %}
        {% elsif default.kind == :i128 %} {% type = Int128 %}
        {% elsif default.kind == :u8 %} {% type = UInt8 %}
        {% elsif default.kind == :u16 %} {% type = UInt16 %}
        {% elsif default.kind == :u32 %} {% type = UInt32 %}
        {% elsif default.kind == :u64 %} {% type = UInt64 %}
        {% elsif default.kind == :u128 %} {% type = UInt128 %}
        {% elsif default.kind == :f32 %} {% type = Float32 %}
        {% elsif default.kind == :f64 %} {% type = Float64 %}
        {% else %} {% raise "reactive: unsupported number literal #{default}" %}
        {% end %}
      {% elsif decl.is_a?(Assign) && (decl.value.is_a?(StringLiteral) || decl.value.is_a?(StringInterpolation)) %}
        {% name = decl.target %}
        {% default = decl.value %}
        {% type = String %}
      {% elsif decl.is_a?(Assign) && decl.value.is_a?(BoolLiteral) %}
        {% name = decl.target %}
        {% default = decl.value %}
        {% type = Bool %}
      {% elsif decl.is_a?(Assign) && decl.value.is_a?(CharLiteral) %}
        {% name = decl.target %}
        {% default = decl.value %}
        {% type = Char %}
      {% elsif decl.is_a?(Assign) && decl.value.is_a?(SymbolLiteral) %}
        {% name = decl.target %}
        {% default = decl.value %}
        {% type = Symbol %}
      {% elsif decl.is_a?(Assign) && decl.value.is_a?(NilLiteral) %}
        {% name = decl.target %}
        {% default = decl.value %}
        {% type = Nil %}
      {% else %}
        {% raise "reactive expects `name = default` or `name : Type = default` (literal defaults only)" %}
      {% end %}
      @{{name.id}} : ::Egui::Signal({{type}}) = ::Egui::Signal({{type}}).new({{default}})
      def {{name.id}} : {{type}}
        @{{name.id}}.value
      end

      # The underlying signal — what `*_binding` Ui helpers take.
      def {{name.id}}_signal : ::Egui::Signal({{type}})
        @{{name.id}}
      end

      def {{name.id}}=(value : {{type}}) : Nil
        sig = @{{name.id}}
        return if sig.value == value
        sig.value = value
        ctx.request_repaint unless ctx.in_frame?
      end
    end

    # `computed doubled : Int32 = count * 2` — a memoized derivation
    # from signals/other computeds. The declaration form is required
    # (not a block): Crystal cannot infer an instance-variable type
    # from a method-call expression, and the annotated value ivar
    # gives change detection a typed old/new pair for free. The block
    # re-runs only when a dirty result is read; a recompute yielding
    # the old value does not propagate further.
    macro computed(decl)
      {% unless decl.is_a?(TypeDeclaration) && decl.value %}
        {% raise "computed expects `name : Type = expression`" %}
      {% end %}
      @{{decl.var.id}}_cell = ::Egui::ComputedCell.new
      @{{decl.var.id}}_value : {{decl.type}}? = nil

      def {{decl.var.id}} : {{decl.type}}
        cell = @{{decl.var.id}}_cell
        ::Egui::ReactiveTracking.read(cell)
        if cell.dirty?
          old = @{{decl.var.id}}_value
          cell.begin_compute
          result = {{decl.value}}
          cell.settle
          @{{decl.var.id}}_value = result
          cell.commit if old.nil? || old != result
        end
        @{{decl.var.id}}_value.not_nil!
      rescue ex
        cell.not_nil!.unpush
        raise ex
      end
    end
  end
end
