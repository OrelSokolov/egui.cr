# Egui::Capybara — Capybara-style system tests INSIDE the app.
#
# The Ruby-Capybara role, headless and instant: a Session drives the real
# `App#update` frames with synthesized input events, finds widgets by
# explicit id / label / kind through the inspector's per-frame metadata
# (`Inspector#record_meta` + `Memory#widget_rects`), clicks/types/drags
# them with the exact press/release frame semantics `Memory#begin_frame`
# classifies clicks by, asserts on the frame's text — and rasterizes any
# state to PNG (`capybara/raster.cr`, no GL). The reproduce-a-bug
# workflow: write a scenario against the app class, run it in-process.
#
#   require "egui/capybara"
#   require "egui/capybara/fonts"   # real glyphs in screenshots
#
#   Egui::Capybara.drive(NotepadApp.new) do |t|
#     t.click "#open"
#     t.fill "search", "hello"
#     t.expect_text "hello.txt"
#     t.screenshot "tmp/notepad.png"
#   end
#
# Suites (fresh app per scenario, ✓/✗ report, failure screenshots):
#
#   suite = Egui::Capybara::Suite.new(-> { NotepadApp.new })
#   suite.scenario "open" do |t| ... end
#   exit suite.run
#
# Core-pure: no backend, no native code, no window. The fonts helper is
# the one optional backend-touched require (freetype-cr, still pure
# Crystal).

require "./capybara/png"
require "./capybara/raster"

module Egui
  module Capybara
    class Error < Exception
    end

    class ElementNotFound < Error
      def initialize(selector : String, dump : String)
        super("no widget matches #{selector.inspect}\n#{dump}")
      end
    end

    class ExpectationFailed < Error
    end

    # One driven app instance: the frame loop, the finders, the actions.
    class Session
      getter app : Egui::App
      getter ctx : Egui::Context
      getter width : Int32
      getter height : Int32
      # Last frame's paint list (`Context#end_frame` return, back-to-front).
      getter commands : Array(PaintCmd) = [] of PaintCmd
      # Extra frame prologue, run between begin_frame and app.update —
      # what the sokol backend does there: client-side chrome
      # (`WindowFrame.show` — the notepad caption tabs live here) and
      # `inspector.before_update`. nil for a bare core frame.
      property before_update : (Egui::Context ->)?
      @time : Float64
      @pointer : Pos2?

      DEFAULT_DT = 1.0 / 60.0

      def initialize(@app : Egui::App, width : Int32 = 1280,
                     height : Int32 = 800, settle_frames : Int32 = 2)
        @ctx = @app.ctx
        @width = width
        @height = height
        @time = 0.0
        @screen = Rect.from_min_size(Pos2.zero,
          Vec2.new(width.to_f64, height.to_f64))
        # Widget metadata recording without the F12 panel.
        @ctx.inspector_enabled = true
        @ctx.inspector.not_nil!.open = false
        # Rects for hit-testing come from PREVIOUS frames — run a couple
        # of settle frames so every on-screen widget is addressable.
        settle_frames.times { step }
      end

      # --- frame driver -----------------------------------------------------

      # Advance one frame with `events` (the low-level escape hatch —
      # everything below is built on this).
      def step(events : Array(Event) | Nil = nil,
               dt : Float64 = DEFAULT_DT) : Nil
        @time += dt
        raw = RawInput.new(@screen, events || [] of Event, @time)
        @ctx.begin_frame(raw)
        @before_update.try &.call(@ctx)
        @app.update(@ctx)
        @commands = @ctx.end_frame
        @pointer = @ctx.input.pointer_pos
      end

      # Idle frames (animations settle, timers tick).
      def idle(frames : Int32 = 1, dt : Float64 = DEFAULT_DT) : Nil
        frames.times { step(dt: dt) }
      end

      # --- finders ------------------------------------------------------------

      # `"#id"` — explicit widget id (`Button.new("OK", id: "save")`);
      # anything else — exact label, then explicit id, then widget kind
      # ("Button"/"button"). Raises ElementNotFound with an on-screen
      # dump on a miss.
      def find(selector : String) : Element
        find?(selector) || raise ElementNotFound.new(selector, dump)
      end

      def find?(selector : String) : Element?
        meta = meta_for(selector)
        meta ? Element.new(self, meta) : nil
      end

      def all(selector : String) : Array(Element)
        metas_for(selector).map { |m| Element.new(self, m) }
      end

      def has_widget?(selector : String) : Bool
        !meta_for(selector).nil?
      end

      # Every interactive widget of the last frame (inspector metadata).
      def widgets : Array(Inspector::WidgetMeta)
        @ctx.inspector.try(&.meta_values) || [] of Inspector::WidgetMeta
      end

      def meta_for(selector : String) : Inspector::WidgetMeta?
        metas_for(selector).first?
      end

      private def metas_for(selector : String) : Array(Inspector::WidgetMeta)
        metas = widgets
        if selector.starts_with?('#')
          name = selector[1..]
          metas.select { |m| m.id_name == name }
        else
          hit = metas.select { |m| m.label == selector }
          return hit unless hit.empty?
          hit = metas.select { |m| m.id_name == selector }
          return hit unless hit.empty?
          metas.select { |m| m.kind.compare(selector, true) == 0 }
        end
      end

      # --- text expectations ---------------------------------------------------

      # Every text the last frame painted.
      def texts : Array(String)
        @commands.select(TextCmd).map(&.text)
      end

      # `partial = false` — a whole text run equals `s`; `true` (default)
      # — any run contains it.
      def has_text?(s : String, partial : Bool = true) : Bool
        ts = texts
        partial ? ts.any?(&.includes?(s)) : ts.includes?(s)
      end

      def expect_text(s : String, partial : Bool = true) : Nil
        return if has_text?(s, partial)
        raise ExpectationFailed.new(
          "expected text #{s.inspect} on screen\n#{dump}")
      end

      def expect_no_text(s : String) : Nil
        return unless has_text?(s)
        raise ExpectationFailed.new(
          "expected no text #{s.inspect} on screen\n#{dump}")
      end

      def expect_visible(selector : String) : Element
        el = find?(selector) ||
             raise(ExpectationFailed.new(
               "expected visible widget #{selector.inspect}\n#{dump}"))
        el
      end

      def expect_hidden(selector : String) : Nil
        return unless (el = find?(selector)) && el.visible?
        raise ExpectationFailed.new(
          "expected #{selector.inspect} to be hidden, found at #{el.rect.inspect}")
      end

      # --- actions ---------------------------------------------------------

      # Click semantics are `Memory#begin_frame`'s: the press frame
      # resolves the click candidate from the PREVIOUS frame's rects,
      # the release frame fires `clicked?` — so a click is a press
      # frame + a release frame (+ one settle frame for popups and
      # state that the click opens).
      def click(selector : String | Element,
                button : PointerButton = :primary) : Nil
        pos = center_of(selector)
        press_at(pos, button)
        release_at(pos, button)
        step
      end

      def double_click(selector : String | Element) : Nil
        pos = center_of(selector)
        2.times do
          press_at(pos)
          release_at(pos)
        end
        step
      end

      def right_click(selector : String | Element) : Nil
        click(selector, button: :secondary)
      end

      def hover(selector : String | Element) : Nil
        pos = center_of(selector)
        step([Event.pointer_moved(pos)])
        @pointer = pos
      end

      # Press-drag-release through `steps` interpolated move frames (the
      # slider/scrollbar gesture).
      def drag(selector : String | Element, to : Pos2 | String | Element,
              steps : Int32 = 8, button : PointerButton = :primary) : Nil
        from = center_of(selector)
        target = case to
                 in Pos2     then to
                 in String   then find(to).center
                 in Element  then to.center
                 end
        press_at(from, button)
        steps.times do |i|
          t = (i + 1).to_f64 / steps
          pos = Pos2.new(from.x + (target.x - from.x) * t,
            from.y + (target.y - from.y) * t)
          step([Event.pointer_moved(pos)])
        end
        release_at(target, button)
        step
      end

      def scroll(delta : Vec2, at : Pos2? = nil) : Nil
        pos = at || @pointer || Pos2.new(@width.to_f64 / 2, @height.to_f64 / 2)
        step([Event.pointer_moved(pos), Event.scroll(delta)])
        step
      end

      # Keyboard: symbols map onto KeyCode names (`:enter`, `:page_up`,
      # `:a`); `ctrl/shift/alt` ride along as modifiers. Two frames on
      # purpose: the press frame carries the modifiers (widgets read
      # them from InputState AFTER all of a frame's events are folded
      # together), the release frame carries CLEAN ones — InputState
      # keeps the last key event's modifiers until another key event
      # replaces them, so a modifier-tagged release would eat the next
      # frame's text input as a shortcut (`fill` = Ctrl+A + type).
      def press_key(key : KeyCode | Symbol,
                    ctrl : Bool = false, shift : Bool = false,
                    alt : Bool = false) : Nil
        code = key.is_a?(KeyCode) ? key : parse_key(key)
        mods = Modifiers.new(ctrl: ctrl, shift: shift, alt: alt)
        step([Event.key_pressed(code, mods)])
        step([Event.key_released(code)])
      end

      # Type text like a keyboard: plain chars batch into one text-input
      # frame, `\n`→Enter, `\t`→Tab, `\b`→Backspace.
      def type(text : String) : Nil
        buf = [] of Char
        idx = 0
        while idx < text.size
          ch = text.char_at(idx)
          idx += 1
          case ch
          when '\n' then flush_text(buf); press_key(:enter)
          when '\t' then flush_text(buf); press_key(:tab)
          when '\b' then flush_text(buf); press_key(:backspace)
          else        buf << ch
          end
        end
        flush_text(buf)
      end

      private def flush_text(buf : Array(Char)) : Nil
        return if buf.empty?
        s = String.build { |io| buf.each { |c| io << c } }
        buf.clear
        step([Event.text_input(s)])
      end

      # Click the field to focus, select all, type (TextEdit replaces
      # the selection on input).
      def fill(selector : String | Element, text : String) : Nil
        click(selector)
        press_key(:a, ctrl: true)
        type(text)
        step
      end

      def move_to(pos : Pos2) : Nil
        step([Event.pointer_moved(pos)])
      end

      # --- screenshot --------------------------------------------------------

      # Rasterize the LAST frame to a PNG at 1× (points == pixels).
      # Text needs real fonts — `require "egui/capybara/fonts"` installs
      # them (CrystalFonts); otherwise text draws as extent boxes.
      def screenshot(path : String) : String
        bg = @ctx.style.visuals.panel_fill
        raster = Raster.new(@width, @height, bg)
        raster.render(@commands)
        Dir.mkdir_p(File.dirname(path))
        File.write(path, raster.to_png)
        path
      end

      # --- debugging -----------------------------------------------------------

      # One line per on-screen widget: kind, explicit id, label, rect.
      def dump : String
        String.build do |io|
          io << "widgets on screen:\n"
          widgets.each do |m|
            io << "  " << m.kind
            io << " #" << m.id_name if m.id_name
            io << " " << m.label.inspect if m.label
            if rect = widget_rect(m)
              io << "  [" << "%.0f" % rect.left << "," << "%.0f" % rect.top <<
                " " << "%.0f" % rect.width << "×" << "%.0f" % rect.height << "]"
            end
            io << "\n"
          end
          io << "texts: " << texts.first(30).inspect << "\n"
        end
      end

      # --- internals ---------------------------------------------------------

      private def press_at(pos : Pos2, button : PointerButton = :primary) : Nil
        step([Event.pointer_moved(pos), Event.pointer_pressed(pos, button)])
        @pointer = pos
      end

      private def release_at(pos : Pos2,
                             button : PointerButton = :primary) : Nil
        step([Event.pointer_released(pos, button)])
        @pointer = pos
      end

      private def center_of(selector : String | Element) : Pos2
        case selector
        in String then find(selector).center
        in Element then selector.center
        end
      end

      private def parse_key(key : Symbol) : KeyCode
        KeyCode.parse?(key.to_s.camelcase) ||
          raise(Error.new("unknown key #{key.inspect}"))
      end

      # The widget's rect: current frame first, previous frame as the
      # fallback (right after an action the new frame may not have it).
      private def widget_rect(meta : Inspector::WidgetMeta) : Rect?
        m = @ctx.memory
        m.widget_rects[meta.id]? || m.prev_widget_rects[meta.id]?
      end

      # A widget found by selector, carrying its last-frame metadata.
      class Element
        getter session : Session
        getter meta : Inspector::WidgetMeta

        def initialize(@session, @meta)
        end

        def id : Id
          @meta.id
        end

        def label : String?
          @meta.label
        end

        def kind : String
          @meta.kind
        end

        def id_name : String?
          @meta.id_name
        end

        def rect : Rect
          r = @session.ctx.memory.widget_rects[@meta.id]? ||
              @session.ctx.memory.prev_widget_rects[@meta.id]?
          r || raise(Error.new(
            "widget #{kind} #{label.inspect} has no rect on screen"))
        end

        def center : Pos2
          rect.center
        end

        # Approximation: intersects the screen viewport.
        def visible? : Bool
          rect.intersects?(@session.viewport)
        end

        def click(*, button : PointerButton = :primary) : Nil
          @session.click(self, button: button)
        end

        def double_click : Nil
          @session.double_click(self)
        end

        def right_click : Nil
          @session.right_click(self)
        end

        def hover : Nil
          @session.hover(self)
        end

        def drag_to(to : Pos2 | String | Element, steps : Int32 = 8) : Nil
          @session.drag(self, to, steps: steps)
        end
      end

      def viewport : Rect
        @screen
      end
    end

    # Mini test runner: fresh app per scenario, ✓/✗ report, failure
    # screenshots into `shots_dir`. Meant for in-app self-test suites
    # (`./bin/app --selftest`) and one-shot repro scripts.
    class Suite
      private struct Scenario
        getter name : String
        getter block : Session ->
        def initialize(@name, &@block : Session ->)
        end
      end

      getter shots_dir : String
      @scenarios = [] of Scenario

      def initialize(@factory : -> Egui::App, @width : Int32 = 1280,
                     @height : Int32 = 800, @shots_dir = "tmp/capybara")
      end

      def scenario(name : String, &block : Session ->) : Nil
        @scenarios << Scenario.new(name) { |s| block.call(s) }
      end

      # Runs everything; returns the failure count (an exit code).
      def run(io : IO = STDOUT) : Int32
        failures = 0
        @scenarios.each do |sc|
          session = Session.new(@factory.call, width: @width,
            height: @height)
          begin
            sc.block.call(session)
            io << "✓ " << sc.name << "\n"
          rescue ex : Error | Exception
            failures += 1
            io << "✗ " << sc.name << "\n"
            io << "  " << ex.class.name << ": " <<
              ex.message.to_s.lines.first? << "\n"
            save_failure_shot(session, sc.name)
          end
        end
        io << "#{@scenarios.size - failures}/#{@scenarios.size} passed\n"
        failures
      end

      private def save_failure_shot(session : Session, name : String) : Nil
        slug = name.downcase.gsub(/[^a-z0-9]+/, "_").strip('_')
        path = File.join(@shots_dir, "fail_#{slug}.png")
        begin
          session.screenshot(path)
          STDERR << "  failure screenshot: " << path << "\n"
        rescue ex
          STDERR << "  (no failure screenshot: " << ex.message << ")\n"
        end
      end
    end

    # One-off drive (single scenario against an app instance).
    def self.drive(app : Egui::App, **opts, &) : Session
      session = Session.new(app, **opts)
      yield session
      session
    end
  end
end
