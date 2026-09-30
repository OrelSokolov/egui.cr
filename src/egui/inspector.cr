# The runtime widget inspector (no upstream counterpart; the closest
# egui has is `ctx.debug_on_hover`). Chrome-DevTools-lite, scoped to
# exactly two edit targets:
#
# * the «Элемент» tab — per-element style overrides
#   (`Context#id_style_overrides`, the top cascade layer; state bags
#   exactly like class rules — the same База/Hover/Active switch);
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
# Frame hooks (driven by the backend / Context#end_frame):
#
#   begin_frame → #before_update   (docked panel + F12 + pick detect)
#   app.update
#   Context#end_frame → #after_update  (pick menu, dock menu, color
#                                      popup, highlight) — after ALL
#                                      app content, the deferred central
#                                      panel included, so the pick
#                                      decision sees every context menu
#                                      the app opened this frame.

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
    # override — optionally state-scoped — or class rule) the open
    # ColorPicker writes to.
    private struct ColorTarget
      getter prop : StyleProp
      getter element_id : Id?
      getter element_state : String?
      getter class_path : String?
      getter class_state : String?

      def initialize(@prop, @element_id = nil, @element_state = nil,
                     @class_path = nil, @class_state = nil)
      end
    end

    PICK_MENU  = "inspector_pick"
    COLOR_POP  = "inspector_color"
    EXPORT_POP = "inspector_export"
    DOCK_MENU  = "inspector_dock"
    PANEL_H    = 190.0
    # Default width of the right column (the bottom strip is PANEL_H):
    # wide enough for the header's action cluster (tabs + Export + ⚙ +
    # ✕ + gaps) even after the panel padding. Exact budget: interior =
    # PANEL_W − 2×10 window padding; the header needs 2×TAB_W + 2 tab
    # gaps + EXPORT_W + MENU_W + CLOSE_W + 3 cluster gaps (+8 item
    # spacing each) = 402 → 422 leaves the spacer's gap non-negative
    # (at 420 the ✕ cell was clamped 26→24 and its glyph spilled).
    PANEL_W    = 422.0
    LABEL_W    = 130.0
    # Header geometry: equal-width tab cells (the «Класс»/«Элемент»
    # pair reads as one control) and the right-pinned action cluster.
    TAB_W      = 80.0
    TAB_H      = 26.0
    EXPORT_W   = 150.0
    MENU_W     = 26.0
    CLOSE_W    = 26.0
    # Property table geometry: fixed columns keep every row aligned —
    # the override marker, the property name, then the editor cells.
    MARK_W     = 22.0
    ROW_H      = 20.0
    # The inspector panel rides its own layer ABOVE app windows (z=98
    # vs Middle/windows z=50) — a debug tool must never be covered —
    # but under its own popups (Foreground z=99: pick menu, color
    # picker, export modal) and tooltips (z=100). Order::Middle keeps
    # modals able to block it (the export modal dims the panel below
    # itself like any other content).
    INSPECTOR_LAYER = LayerId.new(Order::Middle, Id.from("inspector_panel"),
      z: 98)
    # The orange selection outline. It rides a layer ABOVE app windows
    # (z=50) so a selected widget is clearly marked, but BELOW the
    # inspector panel (z=98), popups/modals (99) and tooltips (100) —
    # the outline must never paint over the very tools that edit the
    # widget (the panel itself, the color picker, the export modal).
    HIGHLIGHT_Z     = 60
    HIGHLIGHT_COLOR = Color32.rgb(255, 149, 0)

    getter selected : Id?
    property tab : Symbol                 # :class | :element
    property dock : Symbol                # :right | :bottom — where the panel lives
    property? open : Bool
    property? export_open : Bool
    property export_text : String

    @prev_meta = {} of Id => WidgetMeta
    @meta = {} of Id => WidgetMeta
    @pending_pick : {Id, Pos2}?
    @pick_target : Id?
    @last_selected_meta : WidgetMeta?
    @class_sel : String?
    @class_state : String?
    @element_state : String?
    @color_target : ColorTarget?
    @color_anchor : Pos2
    @dock_rect : Rect    # last frame's dock-menu button rect (popup anchor)

    def initialize(@ctx : Context)
      @open = true
      @tab = :element
      @dock = :right
      @export_open = false
      @export_text = ""
      @color_anchor = Pos2.zero
      @dock_rect = Rect.from_min_size(Pos2.zero, Vec2.zero)
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
    # hug its screen edge (right column or bottom strip), before the
    # app's own panels take their share.
    def before_update : Nil
      self.open = !@open if @ctx.input.consume_key(KeyCode::F12)
      if @ctx.input.secondary_pressed? && (pos = @ctx.input.secondary_pos) &&
         (hit = @ctx.memory.widget_at(pos))
        @pending_pick = {hit, pos}
      end
      render_panel if @open
    end

    # After app.update — called from Context#end_frame once ALL app
    # content has rendered, including the DEFERRED central panel (a
    # widget's context menu attached there opens its popup only at
    # that point, so the pick decision below must run after it): open
    # the pick menu only when NO popup answered the press — a widget
    # with its own context menu gets the «Inspect …» row appended as
    # that menu's last item instead (see #render_menu_tail). Then the
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
      render_dock_menu
      render_color_popup
      render_export_modal
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
      # A fresh selection starts at the base state — a stale Hover (with
      # every non-state row filtered out) would read as an empty table.
      @element_state = nil
      @tab = :element if id
      id
    end

    # Panel visibility (F12 flips it). The backend's `inspector: :hidden`
    # starts closed — enabled but invoked on demand. Closing the panel
    # also drops the selection: the orange outline belongs to the tool,
    # it must not outlive the tool being on screen.
    def open=(flag : Bool) : Bool
      @open = flag
      self.selected = nil unless flag
      flag
    end

    def open? : Bool
      @open
    end

    # Select `id` AND show the panel — the pick menu's action. Picking
    # a widget with the panel hidden must reveal it, not just set the
    # selection (F12 is not the only way back).
    def inspect_widget(id : Id) : Nil
      self.selected = id
      @open = true
    end

    # --- pick menu ----------------------------------------------------------

    # The «Inspect …» row appended to a widget's OWN context menu — the
    # one-menu rule: a widget never gets two context menus, so while
    # the inspector is enabled its entry rides along as the LAST item
    # of whatever menu the widget already opens (`Response#context_menu`)
    # instead of opening a second popup beside it. The standalone pick
    # menu below only exists for widgets WITHOUT a menu of their own.
    def render_menu_tail(ui : Ui, id : Id) : Nil
      return unless m = meta_for(id)
      ui.separator
      ui.menu_item("Inspect #{m.kind} · #{display_name(id, m)}") do
        inspect_widget(id)
      end
    end

    private def render_pick_menu : Nil
      return unless @ctx.popup_open?(PICK_MENU)
      pop_id = Id.from("popup/#{PICK_MENU}")
      anchor = @ctx.memory.areas.pos_for(pop_id, Pos2.zero)
      @ctx.popup(PICK_MENU, anchor, width: 260) do |ui|
        ui.menu_popup_key = PICK_MENU
        if (id = @pick_target) && (m = meta_for(id))
          ui.menu_item("Inspect #{m.kind} · #{display_name(id, m)}") do
            inspect_widget(id)
          end
        end
      end
    end

    # --- export (Copy the live edits into app-ready code) --------------------

    # Build the snippet for the ACTIVE tab and open the modal.
    def open_export : Nil
      @export_text = @tab == :class ? export_class_snippet : export_element_snippet
      @export_open = true
      @ctx.request_repaint
    end

    # The «Элемент» export: the per-id overrides as the exact
    # `Context#set_id_style` calls that reproduce them — base keys
    # first, then each state overlay. Widgets with an explicit id
    # export the stable `Id.from("…")` form; auto ids export the raw
    # value plus a hint to assign an explicit id in code.
    def export_element_snippet : String
      id = @selected
      return "# Ничего не выбрано — правый клик по виджету → «Inspect»." unless id
      m = meta_for(id) || @last_selected_meta
      return "# Виджет не найден (нет данных)." unless m
      id_src = m.id_name ? "Egui::Id.from(#{m.id_name.inspect})" :
                           "Egui::Id.new(0x#{id.value.to_s(16)}_u64)"
      states = @ctx.id_style_overrides[id]?
      String.build do |s|
        s << "# Element style: #{m.kind}"
        s << " «#{m.label}»" if m.label
        s << "\n"
        unless m.id_name
          s << "# (авто-id — назначьте виджету явный id: \"…\", чтобы адресовать его в коде)\n"
        end
        if states.nil? || states.all? { |_st, bag| bag.empty? }
          s << "# (нет per-element правок)\n"
        else
          states.keys.sort_by { |st| st ? 1 : 0 }.each do |st|
            bag = states[st]?
            next if bag.nil? || bag.empty?
            bag.keys.sort.each do |key|
              s << "ctx.set_id_style(#{id_src}, #{key.inspect}, " \
                   "#{style_value_source(bag[key])}"
              s << ", state: #{st.inspect}" if st
              s << ")\n"
            end
          end
        end
      end
    end

    # The «Класс» export: the class's own base rule plus every state
    # overlay, as `StyleSheet#rule` calls ready to paste into the app.
    def export_class_snippet : String
      path = @class_sel || @ctx.stylesheet.classes.first?
      return "# Нет классов." unless path
      String.build do |s|
        s << "# Class style: #{path}\n"
        if (cls = @ctx.stylesheet[path]?) && !cls.vars.empty?
          append_rule(s, path, cls.vars)
        else
          s << "# (базовое правило не задано — всё наследуется от темы)\n"
        end
        cls.try &.states.each do |state, vars|
          append_rule(s, "#{path}:#{state}", vars) unless vars.empty?
        end
      end
    end

    private def append_rule(io : IO, selector : String, vars : StyleVars) : Nil
      io << "ctx.stylesheet.rule(" << selector.inspect << ", Egui::StyleVars{\n"
      vars.keys.sort.each do |key|
        io << "  " << key.inspect << " => " << style_value_source(vars[key]) << ",\n"
      end
      io << "})\n"
    end

    private def style_value_source(v : StyleValue) : String
      case v
      when Color32 then "Egui::Color32.rgb(#{v.r}, #{v.g}, #{v.b})"
      when String  then v.inspect
      else              v.to_s
      end
    end

    private def render_export_modal : Nil
      return unless @export_open
      clicked = @ctx.modal(EXPORT_POP, width: 560, title: "Export style",
        buttons: ["Копировать", "Закрыть"]) do |ui|
        ui.textarea(@export_text, rows: 14) { |t| @export_text = t }
      end
      case clicked
      when "Копировать"
        Egui::SystemPorts::Clipboard.text = @export_text
      when "Закрыть"
        @export_open = false
      end
    end

    # --- selection highlight -------------------------------------------------

    private def highlight_selected : Nil
      return unless id = @selected
      return unless rect = @ctx.memory.prev_widget_rects[id]? ||
                       @ctx.memory.widget_rects[id]?
      p = @ctx.painter
      p.layer = HIGHLIGHT_Z
      p.clip = @ctx.input.screen_rect
      marked = Rect.new(rect.min - Vec2.new(2.0, 2.0),
        rect.max + Vec2.new(2.0, 2.0))
      p.rect(marked, 4.0,
        stroke_color: HIGHLIGHT_COLOR, stroke_width: 1.5)
      p.layer = Order::Background
      p.clip = Rect.new(Pos2.new(-1e9, -1e9), Pos2.new(1e9, 1e9))
    end

    # --- bottom panel ---------------------------------------------------------

    private def render_panel : Nil
      # Chrome-DevTools look: a background DISTINCT from app panels —
      # `panel_fill` blended 5.5% toward the text color reads slightly
      # darker in light themes (#f8f9fa-ish) and slightly lighter in
      # dark ones (#292a2d-ish), like the real DevTools dock.
      v = @ctx.style.visuals
      fill = v.fade_color(v.panel_fill, 0.055)
      if @dock == :right
        # The right column: a top-down panel gets its own auto-scroll
        # from Context#panel_ui, so the tab body needs no nested
        # scroll_area — the overflow is the panel's business.
        @ctx.side_panel(:right, "inspector", width: PANEL_W,
          layer: INSPECTOR_LAYER, fill: fill) do |ui|
          render_header(ui)
          render_tab_body(ui)
        end
      else
        # The bottom strip is a single-row layout — the tab body wraps
        # in its own scroll_area so the header row stays pinned.
        @ctx.bottom_panel("inspector", height: PANEL_H,
          layer: INSPECTOR_LAYER, fill: fill) do |ui|
          render_header(ui)
          ui.scroll_area { |body| render_tab_body(body) }
        end
      end
    end

    private def render_tab_body(ui : Ui) : Nil
      case @tab
      when :class    then render_class_tab(ui)
      when :element  then render_element_tab(ui)
      end
    end

    # The DevTools-style header shared by both docks: tab cells on the
    # left (equal width, active fill + accent underline), the actions
    # pinned to the panel's RIGHT edge (Export with the download icon,
    # the settings dock menu, then ✕) through a spacer consuming the
    # leftover width.
    private def render_header(ui : Ui) : Nil
      ui.horizontal do |row|
        if render_tab(row, "Класс", @tab == :class)
          @tab = :class
        end
        if render_tab(row, "Элемент", @tab == :element)
          @tab = :element
        end
        # Right-pinned cluster: the spacer eats the leftover width so
        # the cluster's LAST item (✕) ends flush at the panel's right
        # edge. Each item_spacing gap after the spacer (spacer→export,
        # export→cog, cog→✕) is part of the cluster's footprint.
        s = row.style.spacing.item_spacing.x
        cluster = EXPORT_W + MENU_W + CLOSE_W + 3 * s
        gap = {row.available_width - cluster, 0.0}.max
        row.allocate_space(Vec2.new(gap, 0.0))
        if row.add_sized(Vec2.new(EXPORT_W, TAB_H),
             Button.new("Export Style", id: "inspector_export_btn")
               .icon(:download)).clicked?
          open_export
        end
        render_dock_menu_button(row)
        # ✕ uses the Lucide X glyph, tinted like the neighboring
        # settings icon (`Icon.from_file` — compile-time embedded,
        # parsed once per tint).
        self.open = false if row.add_sized(Vec2.new(CLOSE_W, TAB_H),
          Button.new("", id: "inspector_close")
            .icon(Icon.from_file(:lucide, :x,
              tint: row.style.visuals.text_color))).clicked?
      end
    end

    # One header tab: a fixed-size clickable cell (equal widths keep
    # the «Класс»/«Элемент» pair reading as one control). The active
    # tab gets the DevTools treatment — a soft fill plus an accent
    # underline along the bottom edge. Returns true when clicked.
    private def render_tab(row : Ui, label : String, active : Bool) : Bool
      v = row.style.visuals
      rect = row.allocate_space(Vec2.new(TAB_W, TAB_H))
      resp = row.interact(rect, row.next_widget_id, Sense.click)
      if active
        row.painter.rect(rect, 4.0, v.button_weak)
        row.painter.line(Pos2.new(rect.left, rect.bottom - 1.0),
          Pos2.new(rect.right, rect.bottom - 1.0), 2.0, v.selection_fill)
      elsif resp.hovered?
        row.painter.rect(rect, 4.0, v.fade_color(v.button_weak, 0.5))
      end
      font = row.style.font_size
      w = row.ctx.fonts.measure(label, font).x
      color = active ? v.text_color : v.fade_color(v.text_color, 0.6)
      row.painter.text(Pos2.new(rect.center.x - w / 2.0, rect.center.y),
        label, font, color)
      resp.clicked?
    end

    # The settings-gear dock switcher: a fixed-size icon
    # button opening a dropdown with the dock choices. Hand-rolled like
    # #render_tab — the shared Ui#menu_button stretches to the row's
    # full height. The open/close bookkeeping rides the same
    # Memory#menu_open + popup pair menu_button uses (a click elsewhere
    # closes the popup and clears menu_open in Memory#end_frame).
    private def render_dock_menu_button(row : Ui) : Nil
      v = row.style.visuals
      rect = row.allocate_space(Vec2.new(MENU_W, TAB_H))
      @dock_rect = rect
      resp = row.interact(rect, row.next_widget_id, Sense.click)
      mine_open = @ctx.memory.menu_open == DOCK_MENU
      if resp.clicked?
        if mine_open
          @ctx.memory.menu_open = nil
          @ctx.close_popup(DOCK_MENU)
        else
          @ctx.memory.menu_open = DOCK_MENU
          @ctx.open_popup(DOCK_MENU)
        end
      end
      if mine_open
        row.painter.rect(rect, 4.0, v.button_active)
      elsif resp.hovered?
        row.painter.rect(rect, 4.0, v.button_hovered)
      end
      # The settings gear comes straight from the vendored Lucide set
      # (`icons/lucide/settings.svg`) through `Icon.from_file` — compile-time
      # embedded, parsed once per tint.
      Icon.from_file(:lucide, :settings, tint: v.text_color).paint(row,
        Rect.from_min_size(
          Pos2.new(rect.center.x - 7.0, rect.center.y - 7.0),
          Vec2.new(14.0, 14.0)))
    end

    # The settings dropdown: where the panel lives. A check marks the
    # current dock; picking one re-docks the panel on the next frame.
    private def render_dock_menu : Nil
      return unless @ctx.popup_open?(DOCK_MENU)
      anchor = @ctx.dropdown_anchor(DOCK_MENU, @dock_rect)
      @ctx.popup(DOCK_MENU, anchor, width: 150.0) do |ui|
        ui.menu_popup_key = DOCK_MENU
        ui.menu_item("Right", icon: @dock == :right ? :check : nil) do
          @dock = :right
        end
        ui.menu_item("Bottom", icon: @dock == :bottom ? :check : nil) do
          @dock = :bottom
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
        render_state_switch(ui, @class_state) { |st| @class_state = st }
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

      render_table_header(ui)
      props.each do |prop|
        next if state && !prop.states?
        render_prop_row(ui, prop, vars, set_here.call(prop.key),
          setter: set, unsetter: unset,
          color_target: ColorTarget.new(prop, class_path: path,
            class_state: state),
          theme_state: state)
      end
    end

    # The «База / Hover / Active» switch shared by both tabs — the
    # element layer stores per-state bags exactly like class rules.
    private def render_state_switch(ui : Ui, current : String?,
                                    &set : String? ->) : Nil
      ui.horizontal do |row|
        row.label("Состояние:")
        {"База" => nil, "Hover" => "hover", "Active" => "active"}.each do |label, st|
          row.selectable(current == st, label) { |_| set.call(st) }
        end
      end
    end

    # --- the «Элемент» tab: edits per-id overrides ----------------------------

    private def render_element_tab(ui : Ui) : Nil
      id = @selected
      if id.nil?
        ui.label("Ничего не выбрано — правый клик по виджету → «Inspect». F12 — вкл/выкл панели.")
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

      # The same База/Hover/Active switch as the Class tab: the
      # element layer stores per-state bags (`Context#set_id_style`
      # with a state), so a single `background` key covers every
      # state — no separate per-state properties.
      if m.props.any?(&.states?)
        render_state_switch(ui, @element_state) { |st| @element_state = st }
      end
      state = @element_state

      vars = element_vars(id, m, state)
      overrides = @ctx.id_style_state_vars(id, state)
      set = ->(k : String, v : StyleValue) { @ctx.set_id_style(id, k, v, state) }
      unset = ->(k : String) { @ctx.clear_id_style(id, k, state) }

      render_table_header(ui)
      m.props.each do |prop|
        next if state && !prop.states?
        set_here = !!overrides.try(&.has_key?(prop.key)) ||
                   (prop.kind == :box && box_set?(overrides, prop.key))
        render_prop_row(ui, prop, vars, set_here,
          setter: set, unsetter: unset,
          color_target: ColorTarget.new(prop, element_id: id,
            element_state: state),
          theme_state: state)
      end
    end

    # --- shared property row ---------------------------------------------------

    # One property row of the table: [override marker] [name] [editor].
    # The marker checkbox IS the override switch — ✓ sets the value at
    # this scope (seeded from what's on screen), untick removes the
    # override so the property falls back to its inherited value.
    # `vars` is the merged display source (class rules + override); the
    # procs write/unset at the row's own scope (element id or class rule).
    private def render_prop_row(ui : Ui, prop : StyleProp, vars : StyleVars,
                                set_here : Bool,
                                setter : Proc(String, StyleValue, Nil),
                                unsetter : Proc(String, Nil),
                                color_target : ColorTarget,
                                theme_state : String? = nil) : Nil
      y0 = ui.cursor.y
      col_x = 0.0
      ui.horizontal do |row|
        # Pin the row height upfront: the marker checkbox is the SHORTEST
        # thing here (14px icon) and arrives FIRST — centered in the
        # generic 18px row seed it would sit 1px above the row's true
        # center once the 20px name cell grows the row, and every taller
        # item (text, editors) would read as hanging below it.
        row.seed_row_height(ROW_H)
        row.checkbox(set_here, "") do |v|
          if v
            # Turning the override on starts from the current display
            # value, so the editor opens on what's already visible.
            case prop.kind
            when :color  then setter.call(prop.key, display_color_value(prop, vars, theme_state))
            when :number then setter.call(prop.key, display_number(prop, vars))
            when :bool   then setter.call(prop.key, display_bool(prop, vars))
            when :string then setter.call(prop.key, display_string(prop, vars))
            when :box
              b = display_box(prop, vars)
              setter.call("#{prop.key}.top", b.top)
              setter.call("#{prop.key}.right", b.right)
              setter.call("#{prop.key}.bottom", b.bottom)
              setter.call("#{prop.key}.left", b.left)
            end
          else
            unset_prop(prop, unsetter)
          end
        end
        # Fixed-width name column — every editor below starts at the
        # same x, which is what makes the rows read as a table.
        col_x = row.cursor.x
        row.add_sized(Vec2.new(LABEL_W, ROW_H), Label.new(prop.label))

        case prop.kind
        when :bool
          row.checkbox(display_bool(prop, vars), "") do |v|
            setter.call(prop.key, v)
          end
        when :color
          color = display_color_value(prop, vars, theme_state)
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
          value = display_number(prop, vars)
          row.drag_value(value, speed: prop_speed(prop.key)) do |v|
            setter.call(prop.key, v)
          end
        when :box
          b = display_box(prop, vars)
          {"top" => b.top, "right" => b.right,
           "bottom" => b.bottom, "left" => b.left}.each do |side, v|
            row.drag_value(v, speed: 1.0, prefix: side[0].upcase.to_s) do |nv|
              # Same clamp as StyleVars#box — keep the stored sheet value
              # sane, not just the read side.
              setter.call("#{prop.key}.#{side}", {nv, 0.0}.max)
            end
          end
        when :string
          # Free-text editor (font family names); empty means "unset"
          # for keys whose fallback is the theme slot.
          value = display_string(prop, vars)
          row.text_edit_singleline(value) do |text|
            setter.call(prop.key, text)
          end
        end
      end
      paint_table_row(ui, y0, col_x)
    end

    # The table's header row: «Свойство | Значение» over the same fixed
    # columns the property rows use, with a stronger rule underneath.
    private def render_table_header(ui : Ui) : Nil
      v = ui.style.visuals
      muted = v.fade_color(v.text_color, 0.45)
      font = ui.style.font_size
      y0 = ui.cursor.y
      col_x = 0.0
      ui.horizontal do |row|
        row.seed_row_height(ROW_H)
        row.allocate_space(Vec2.new(MARK_W, ROW_H))
        col_x = row.cursor.x
        name = row.allocate_space(Vec2.new(LABEL_W, ROW_H))
        row.painter.text(Pos2.new(name.left + 2.0, name.center.y),
          "Свойство", font, muted)
        value = row.allocate_space(Vec2.new(120.0, ROW_H))
        row.painter.text(Pos2.new(value.left + 2.0, value.center.y),
          "Значение", font, muted)
      end
      paint_table_row(ui, y0, col_x, header: true)
    end

    # The table grid: a horizontal rule under every row and a vertical
    # rule between the name and value columns (per row — the segments
    # stack into continuous table borders). Called after the row's
    # `horizontal` block, when the cursor sits just below the row.
    # The horizontal rule rides the MIDDLE of the inter-row gap, not the
    # row's bottom edge: the eye reads the band BETWEEN two rules as the
    # row, and with the rule at the bottom edge the whole item_spacing
    # gap lands above the next row — its content then sits ~3px below
    # the band's centerline and every row reads as sagging downward.
    private def paint_table_row(ui : Ui, y0 : Float64, col_x : Float64,
                                header : Bool = false) : Nil
      v = ui.style.visuals
      spacing = ui.style.spacing.item_spacing.y
      bottom = ui.cursor.y - spacing / 2.0
      left = ui.cursor.x
      right = left + ui.available_width
      row_color = v.fade_color(v.separator_color, 0.5)
      ui.painter.line(Pos2.new(left, bottom), Pos2.new(right, bottom), 1.0,
        header ? v.fade_color(v.text_color, 0.3) : row_color)
      ui.painter.line(Pos2.new(col_x, y0 - spacing / 2.0),
        Pos2.new(col_x, bottom), 1.0, row_color)
    end

    # Remove one property's override at the row's scope. Box props are
    # stored per side ("padding.top" …) plus the scalar key, so all
    # five variants must go for the row to read as inherited again.
    private def unset_prop(prop : StyleProp,
                           unsetter : Proc(String, Nil)) : Nil
      if prop.kind == :box
        {"", ".top", ".right", ".bottom", ".left"}.each do |sfx|
          unsetter.call("#{prop.key}#{sfx}")
        end
      else
        unsetter.call(prop.key)
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
            @ctx.set_id_style(id, t.prop.key, c, t.element_state)
          elsif (path = t.class_path)
            sel = t.class_state ? "#{path}:#{t.class_state}" : path
            @ctx.stylesheet.rule(sel, StyleVars{t.prop.key => c})
            @ctx.request_repaint
          end
        end
        if ui.button("Снять override").clicked?
          if (id = t.element_id)
            @ctx.clear_id_style(id, t.prop.key, t.element_state)
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

    # --- display-value resolution ---------------------------------------------
    #
    # A key's effective value comes from three places, and the editor
    # rows must show the REAL one, not a bogus 0/gray: the merged vars
    # bag (class rules + override) → the theme slot the key maps onto
    # (`StyleVars#apply_over` vocabulary — font_size lives in the theme
    # Style, not in any class rule) → the widget's own hardcoded
    # default (`StyleProp#fallback`, e.g. Button rounding 4.0).

    private def display_number(prop : StyleProp, vars : StyleVars) : Float64
      if (v = vars.f64?(prop.key))
        return v
      end
      if (t = theme_number(prop.key))
        return t
      end
      case f = prop.fallback
      when Float64 then f
      when Int32   then f.to_f64
      else              0.0
      end
    end

    # Bool props have no theme layer — unset reads as the widget's own
    # fallback (`StyleProp#fallback`, e.g. ToggleButton sync_with_text).
    private def display_bool(prop : StyleProp, vars : StyleVars) : Bool
      vars.bool?(prop.key) || prop.fallback.as?(Bool) || false
    end

    # String props (font families): the merged vars → the theme slot
    # (`Style#font_family`) → the widget's own default ("monospace" for
    # the terminal grid). Empty string renders as an unset value.
    private def display_string(prop : StyleProp, vars : StyleVars) : String
      vars.str?(prop.key) || theme_string(prop.key) ||
        prop.fallback.as?(String) || ""
    end

    private def display_color_value(prop : StyleProp, vars : StyleVars,
                                    theme_state : String? = nil) : Color32
      vars.color?(prop.key) || theme_color(prop.key, theme_state) ||
        prop.fallback.as?(Color32) || Color32.rgb(120, 120, 120)
    end

    private def display_box(prop : StyleProp, vars : StyleVars) : StyleBox
      vars.box?(prop.key) ||
        (if prop.key == "padding"
           # Buttons/checkboxes fall back to the theme's symmetric
           # button padding when the class leaves it unset.
           bp = @ctx.style.spacing.button_padding
           StyleBox.new(bp.y, bp.x, bp.y, bp.x)
         else
           StyleBox.new
         end)
    end

    # The theme slot behind a color key (the reverse of the
    # `StyleVars#apply_over` key→slot mapping). `background` is
    # state-scoped: its theme fallback is the Visuals slot OF that
    # state — the user-agent pseudo-class rules, CSS-style.
    private def theme_color(key : String, state : String? = nil) : Color32?
      v = @ctx.style.visuals
      case key
      when "background"
        case state
        when "hover"  then v.button_hovered
        when "active" then v.button_active
        else               v.button_weak
        end
      when "text_color"       then v.text_color
      when "stroke"           then v.button_stroke
      when "selection_fill"   then v.selection_fill
      when "hyperlink_color"  then v.hyperlink_color
      when "separator_color"  then v.separator_color
      else                         nil
      end
    end

    private def theme_number(key : String) : Float64?
      case key
      when "font_size" then @ctx.style.font_size
      else                  nil
      end
    end

    # The theme slot behind a string key (see #theme_color).
    private def theme_string(key : String) : String?
      case key
      when "font_family" then @ctx.style.font_family
      else                    nil
      end
    end

    private def display_name(id : Id, m : WidgetMeta) : String
      m.id_name || id.short_label
    end

    private def display_color(t : ColorTarget) : Color32
      if (id = t.element_id) && (m = meta_for(id) || @last_selected_meta)
        display_color_value(t.prop, element_vars(id, m, t.element_state),
          t.element_state)
      elsif (path = t.class_path)
        display_color_value(t.prop,
          @ctx.stylesheet.resolve(path, t.class_state), t.class_state)
      else
        @ctx.style.visuals.text_color
      end
    end

    # Merged display source for the Element tab: the class rules (with
    # the state overlay) plus the per-element override of the same
    # state (mirrors `Widget#style_vars`).
    private def element_vars(id : Id, m : WidgetMeta,
                             state : String? = nil) : StyleVars
      vars = m.style_class ? @ctx.stylesheet.resolve(m.style_class.not_nil!, state) : StyleVars.new
      if (ov = @ctx.id_style_state_vars(id, state))
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
