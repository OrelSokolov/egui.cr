# The runtime widget inspector (no upstream counterpart; the closest
# egui has is `ctx.debug_on_hover`). Chrome-DevTools-lite, scoped to
# exactly two edit targets:
#
# * the «Элемент» tab — per-element style overrides
#   (`Context#id_style_overrides`, the top cascade layer);
# * the «Класс» tab — the class rules of the active `StyleSheet`
#   (`StyleSheet#rule`, persistable by the app).
#
# No widget tree, no parents: a widget's identity is its `Id` — the
# explicit one (`Button.new("OK", id: "save")`) or the silent auto id
# every widget gets (displayed as a random-looking 6-char name,
# `Id#short_label`).
#
# Which properties exist is declared by the widgets themselves
# (`Widget#style_properties`) — this file is generic: it renders
# whatever the declarations say, and shows "no stylable properties"
# for widgets that declare none.
#
# Frame hooks (driven by the backend around app.update):
#
#   begin_frame → #before_update   (bottom panel + F12 + pick detect)
#   app.update
#   #after_update                   (pick menu, color popup, highlight)

module Egui
  class Inspector
    # Everything the inspector needs to know about a widget that
    # interacted this frame — recorded from `Context#interact` (the
    # `current_widget` set by `Ui#add`).
    class WidgetMeta
      getter kind : String          # short class name ("Button")
      getter style_class : String?
      getter props : Array(StyleProp)
      getter id_name : String?      # explicit id, if any
      getter label : String?        # text-ish human label

      def initialize(widget : Widget)
        @kind = widget.class.name.split("::").last
        @style_class = widget.style_class
        @props = widget.style_properties
        @id_name = widget.id_name
        @label = widget.inspector_label
      end
    end

    # The color popup's edit target: which key of which scope (element
    # override or class rule) the open ColorPicker writes to.
    private struct ColorTarget
      getter prop : StyleProp
      getter element_id : Id?
      getter class_path : String?
      getter class_state : String?

      def initialize(@prop, @element_id = nil, @class_path = nil,
                     @class_state = nil)
      end
    end

    PICK_MENU  = "inspector_pick"
    COLOR_POP  = "inspector_color"
    PANEL_H    = 190.0
    LABEL_W    = 130.0

    getter selected : Id?
    property tab : Symbol                 # :class | :element
    property? open : Bool

    @prev_meta = {} of Id => WidgetMeta
    @meta = {} of Id => WidgetMeta
    @pending_pick : {Id, Pos2}?
    @pick_target : Id?
    @last_selected_meta : WidgetMeta?
    @class_sel : String?
    @class_state : String?
    @color_target : ColorTarget?
    @color_anchor : Pos2

    def initialize(@ctx : Context)
      @open = true
      @tab = :element
      @color_anchor = Pos2.zero
    end

    # --- frame hooks -------------------------------------------------------

    def begin_frame : Nil
      @prev_meta = @meta
      @meta = {} of Id => WidgetMeta
      @pending_pick = nil
    end

    # Record (id → widget) while the frame runs; only called when the
    # inspector is enabled, so the off case costs one branch.
    def record_meta(id : Id, widget : Widget?) : Nil
      return unless widget
      @meta[id] = WidgetMeta.new(widget)
    end

    # Before app.update: the panel must bite #available_rect first to
    # sit at the very bottom edge, under the app's own panels.
    def before_update : Nil
      @open = !@open if @ctx.input.consume_key(KeyCode::F12)
      if @ctx.input.secondary_pressed? && (pos = @ctx.input.secondary_pos) &&
         (hit = @ctx.memory.widget_at(pos))
        @pending_pick = {hit, pos}
      end
      render_panel if @open
    end

    # After app.update: open the pick menu (yielding to any popup the
    # app itself opened this frame — its context menus win), then the
    # overlays that must paint above everything.
    def after_update : Nil
      if (pk = @pending_pick) && !@ctx.popup_opened_this_frame?
        pop_id = Id.from("popup/#{PICK_MENU}")
        @ctx.memory.areas.set_pos(pop_id, pk[1])
        @ctx.open_popup(PICK_MENU)
        @pick_target = pk[0]
      end
      @pending_pick = nil
      render_pick_menu
      render_color_popup
      highlight_selected
    end

    # --- public query API (specs / app introspection) ----------------------

    def meta_for(id : Id) : WidgetMeta?
      @meta[id]? || @prev_meta[id]?
    end

    # Every meta recorded this frame (specs / introspection).
    def meta_values : Array(WidgetMeta)
      @meta.values
    end

    def selected=(id : Id?) : Id?
      @selected = id
      @last_selected_meta = id ? meta_for(id) : nil
      @tab = :element if id
      id
    end

    # --- pick menu ----------------------------------------------------------

    private def render_pick_menu : Nil
      return unless @ctx.popup_open?(PICK_MENU)
      pop_id = Id.from("popup/#{PICK_MENU}")
      anchor = @ctx.memory.areas.pos_for(pop_id, Pos2.zero)
      @ctx.popup(PICK_MENU, anchor, width: 260) do |ui|
        ui.menu_popup_key = PICK_MENU
        if (id = @pick_target) && (m = meta_for(id))
          ui.menu_item("Inspect #{m.kind} · #{display_name(id, m)}") do
            self.selected = id
          end
        end
      end
    end

    # --- selection highlight -------------------------------------------------

    private def highlight_selected : Nil
      return unless id = @selected
      return unless rect = @ctx.memory.prev_widget_rects[id]? ||
                       @ctx.memory.widget_rects[id]?
      p = @ctx.painter
      p.layer = Order::Tooltip
      p.clip = @ctx.input.screen_rect
      marked = Rect.new(rect.min - Vec2.new(2.0, 2.0),
        rect.max + Vec2.new(2.0, 2.0))
      p.rect(marked, 4.0,
        stroke_color: @ctx.style.visuals.selection_fill, stroke_width: 1.5)
      p.layer = Order::Background
      p.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # --- bottom panel ---------------------------------------------------------

    private def render_panel : Nil
      @ctx.bottom_panel("inspector", height: PANEL_H) do |ui|
        ui.horizontal do |row|
          row.selectable(@tab == :class, "Класс") { |_| @tab = :class }
          row.selectable(@tab == :element, "Элемент") { |_| @tab = :element }
          row.label("F12 — вкл/выкл")
          @open = false if row.button("✕", id: "inspector_close").clicked?
        end
        content = ui.child_ui(
          Rect.new(ui.cursor, Pos2.new(ui.max_rect.right, ui.max_rect.bottom)),
          layout: Layout.top_down)
        case @tab
        when :class    then render_class_tab(content)
        when :element  then render_element_tab(content)
        end
      end
    end

    # --- the «Класс» tab: edits `StyleSheet` rules ----------------------------

    private def render_class_tab(ui : Ui) : Nil
      classes = class_choices
      if classes.empty?
        ui.label("Нет классов — виджеты ещё не рисовали кадр.")
        return
      end
      @class_sel = classes.includes?(@class_sel.to_s) ? @class_sel : classes.first
      path = @class_sel.not_nil!

      ui.horizontal do |row|
        row.label("Класс:")
        row.combo_box("insp_class", path, classes, 180.0) do |c|
          @class_sel = c
        end
      end

      props = class_props(path)
      if props.empty?
        ui.label("Нет виджетов класса «#{path}» в кадре — свойства неизвестны.")
        return
      end

      if props.any?(&.states?)
        ui.horizontal do |row|
          row.label("Состояние:")
          states = {"База" => nil, "Hover" => "hover", "Active" => "active"} of String => String?
          states.each do |label, st|
            row.selectable(@class_state == st, label) { |_| @class_state = st }
          end
        end
      end

      state = @class_state
      sel = state ? "#{path}:#{state}" : path
      vars = @ctx.stylesheet.resolve(path, state)
      set_here = ->(k : String) do
        if (st = state)
          !!@ctx.stylesheet.state_vars(path, st).try(&.has_key?(k))
        else
          !!@ctx.stylesheet[path]?.try(&.vars.has_key?(k))
        end
      end
      set = ->(k : String, v : StyleValue) do
        @ctx.stylesheet.rule(sel, StyleVars{k => v})
        @ctx.request_repaint
      end
      unset = ->(k : String) do
        @ctx.stylesheet.unset(sel, k)
        @ctx.request_repaint
      end

      props.each do |prop|
        next if state && !prop.states?
        render_prop_row(ui, prop, vars, set_here.call(prop.key),
          setter: set, unsetter: unset,
          color_target: ColorTarget.new(prop, class_path: path,
            class_state: state))
      end
    end

    # --- the «Элемент» tab: edits per-id overrides ----------------------------

    private def render_element_tab(ui : Ui) : Nil
      id = @selected
      if id.nil?
        ui.label("Ничего не выбрано — правый клик по виджету → «Inspect».")
        return
      end
      m = meta_for(id) || @last_selected_meta
      if m.nil?
        ui.label("Виджет не найден (нет данных).")
        return
      end
      @last_selected_meta = m

      ui.horizontal do |row|
        row.label("#{m.kind} · #{display_name(id, m)}")
        if rect = @ctx.memory.prev_widget_rects[id]? ||
                   @ctx.memory.widget_rects[id]?
          row.label("#{"%.0f" % rect.width} × #{"%.0f" % rect.height}")
        end
        unless @meta.has_key?(id)
          row.label("(не в этом кадре)")
        end
        if row.button("Сбросить всё", id: "insp_reset_all").clicked?
          @ctx.clear_id_style(id)
        end
      end

      if m.props.empty?
        ui.label("Виджет не имеет стилизуемых свойств.")
        return
      end

      vars = element_vars(id, m)
      overrides = @ctx.id_style_overrides[id]?
      set = ->(k : String, v : StyleValue) { @ctx.set_id_style(id, k, v) }
      unset = ->(k : String) { @ctx.clear_id_style(id, k) }

      m.props.each do |prop|
        set_here = !!overrides.try(&.has_key?(prop.key)) ||
                   (prop.kind == :box && box_set?(overrides, prop.key))
        render_prop_row(ui, prop, vars, set_here,
          setter: set, unsetter: unset,
          color_target: ColorTarget.new(prop, element_id: id))
      end
    end

    # --- shared property row ---------------------------------------------------

    # One property: [override checkbox] [label] [editor by kind] [× reset].
    # `vars` is the merged display source (class rules + override); the
    # procs write/unset at the row's own scope (element id or class rule).
    private def render_prop_row(ui : Ui, prop : StyleProp, vars : StyleVars,
                                set_here : Bool,
                                setter : Proc(String, StyleValue, Nil),
                                unsetter : Proc(String, Nil),
                                color_target : ColorTarget) : Nil
      ui.horizontal do |row|
        if prop.kind == :bool
          value = vars.bool(prop.key, false)
          row.checkbox(set_here && value, prop.label) do |v|
            setter.call(prop.key, v)
          end
        else
          row.checkbox(set_here, "") do |v|
            if v
              # Turning the override on starts from the current display
              # value, so the editor opens on what's already visible.
              case prop.kind
              when :color
                setter.call(prop.key,
                  vars.color?(prop.key) || Color32.rgb(120, 120, 120))
              when :number
                setter.call(prop.key, vars.f64(prop.key, 0.0))
              when :box
                b = vars.box(prop.key)
                setter.call("#{prop.key}.top", b.top)
                setter.call("#{prop.key}.right", b.right)
                setter.call("#{prop.key}.bottom", b.bottom)
                setter.call("#{prop.key}.left", b.left)
              end
            end
          end
          row.add_sized(Vec2.new(LABEL_W, 18.0), Label.new(prop.label))
        end

        case prop.kind
        when :color
          color = vars.color?(prop.key) || Color32.rgb(120, 120, 120)
          swatch = row.allocate_space(Vec2.new(20.0, 14.0))
          resp = row.interact(swatch, row.next_widget_id, Sense.click)
          row.painter.rect(swatch, 3.0, color,
            @ctx.style.visuals.button_stroke, 1.0)
          if resp.clicked?
            @color_target = color_target
            @color_anchor = Pos2.new(swatch.left, swatch.bottom + 2.0)
            pop_id = Id.from("popup/#{COLOR_POP}")
            @ctx.memory.areas.set_pos(pop_id, @color_anchor)
            @ctx.open_popup(COLOR_POP)
          end
        when :number
          value = vars.f64(prop.key, 0.0)
          row.drag_value(value, speed: prop_speed(prop.key)) do |v|
            setter.call(prop.key, v)
          end
        when :box
          b = vars.box(prop.key)
          {"top" => b.top, "right" => b.right,
           "bottom" => b.bottom, "left" => b.left}.each do |side, v|
            row.drag_value(v, speed: 1.0, prefix: side[0].upcase.to_s) do |nv|
              setter.call("#{prop.key}.#{side}", nv)
            end
          end
        end

        if row.button("×", id: "insp_unset_#{prop.key.gsub('.', '_')}").clicked?
          unsetter.call(prop.key)
        end
      end
    end

    # The open color popup: a ColorPicker over the pending target.
    private def render_color_popup : Nil
      if !@ctx.popup_open?(COLOR_POP)
        @color_target = nil
        return
      end
      t = @color_target
      pop_id = Id.from("popup/#{COLOR_POP}")
      anchor = @ctx.memory.areas.pos_for(pop_id, @color_anchor)
      @ctx.popup(COLOR_POP, anchor, width: 220) do |ui|
        if t.nil?
          ui.label("(цель потеряна)")
          next
        end
        current = display_color(t)
        ui.color_edit32(current) do |c|
          if (id = t.element_id)
            @ctx.set_id_style(id, t.prop.key, c)
          elsif (path = t.class_path)
            sel = t.class_state ? "#{path}:#{t.class_state}" : path
            @ctx.stylesheet.rule(sel, StyleVars{t.prop.key => c})
            @ctx.request_repaint
          end
        end
        if ui.button("Снять override").clicked?
          if (id = t.element_id)
            @ctx.clear_id_style(id, t.prop.key)
          elsif (path = t.class_path)
            sel = t.class_state ? "#{path}:#{t.class_state}" : path
            @ctx.stylesheet.unset(sel, t.prop.key)
            @ctx.request_repaint
          end
          @ctx.close_popup(COLOR_POP)
        end
      end
    end

    # --- helpers ---------------------------------------------------------------

    private def display_name(id : Id, m : WidgetMeta) : String
      m.id_name || id.short_label
    end

    private def display_color(t : ColorTarget) : Color32
      if (id = t.element_id) && (m = meta_for(id) || @last_selected_meta)
        element_vars(id, m).color?(t.prop.key) ||
          @ctx.style.visuals.text_color
      elsif (path = t.class_path)
        @ctx.stylesheet.resolve(path, t.class_state)
          .color?(t.prop.key) || @ctx.style.visuals.text_color
      else
        @ctx.style.visuals.text_color
      end
    end

    # Merged display source for the Element tab: the class rules plus
    # the per-element override (mirrors `Widget#style_vars`).
    private def element_vars(id : Id, m : WidgetMeta) : StyleVars
      vars = m.style_class ? @ctx.stylesheet.resolve(m.style_class.not_nil!) : StyleVars.new
      if (ov = @ctx.id_style_overrides[id]?)
        merged = StyleVars.new
        merged.merge!(vars)
        merged.merge!(ov)
        merged
      else
        vars
      end
    end

    # A box prop counts as "set" when any side or the scalar is set.
    private def box_set?(overrides : StyleVars?, key : String) : Bool
      return false unless ov = overrides
      {"", ".top", ".right", ".bottom", ".left"}.any? do |suffix|
        ov.has_key?("#{key}#{suffix}")
      end
    end

    private def class_choices : Array(String)
      seen = (@meta.values + @prev_meta.values)
        .map(&.style_class).compact.uniq
      (seen + @ctx.stylesheet.classes).uniq.sort
    end

    # Union of the property declarations of every widget of this class
    # seen in the last two frames (deduped by key).
    private def class_props(path : String?) : Array(StyleProp)
      return [] of StyleProp unless path
      out = [] of StyleProp
      (@meta.values + @prev_meta.values).each do |m|
        next unless m.style_class == path
        m.props.each do |p|
          out << p unless out.any? { |e| e.key == p.key }
        end
      end
      out
    end

    private def prop_speed(key : String) : Float64
      case key
      when "font_size"       then 0.5
      when "shadow.blur"     then 1.0
      when .includes?("blur") then 1.0
      else 0.25
      end
    end
  end
end
