# Wizard — the classic Windows-wizard LAYOUT as a reusable component:
# a banner header (bold title + smaller subtitle) over a body area and
# a footer row of buttons — Back | Next | Cancel — with the last
# step's Next turning into Finish. The structure follows the Windows
# XP-era wizard template; the COLORS come from the active theme, not
# from any copied palette.
#
# The split the template asks for:
#
#   * `WizardStep` — one page of the wizard: title, subtitle, a body
#     block (any widgets), and WHAT THE FOOTER SHOWS — the standard
#     button set by default (back/next/cancel with Wizard-driven
#     behavior), or a fully custom `buttons` list ("this step has
#     three buttons with these actions").
#   * `Wizard` — the container: step order, navigation state, the
#     chrome. It renders inside a Context#embedded_window (dragging,
#     Escape/scrim/✕ dismissal come along for free).
#
#   wizard = Egui::Wizard.new("Setup Wizard", [
#     Egui::WizardStep.new("Welcome", "This wizard installs My App.") do |ui|
#       ui.label("Click Next to continue.")
#     end,
#     Egui::WizardStep.new("Options", "Pick the install type.") do |ui|
#       ui.radio_button(...) ...
#     end,
#   ])
#   step2.on_next { |w| puts "side effects before advancing" }
#   step2.can_next { |w| w.app_data_valid } # gates Next while false
#
#   @open = false if @open && wizard.show(ctx)  # each frame while open
#
# Styling goes through the global `StyleSheet`:
#   wizard.header  — background, text_color, subtitle_color
#   wizard.button  — the footer buttons (the style scope chains real
#                    widgets inside the wizard onto "wizard.*")
# The theme presets ship the defaults (`default_theme.cr`).

module Egui
  class Wizard
    # Element classes for `StyleSheet` tweaks from app code.
    ROOT_CLASS   = "wizard"
    HEADER_CLASS = "wizard.header"

    # Geometry (points): banner height, footer button floor (the Win32
    # dialog button size, 75×23), content insets.
    BANNER_H = 64.0
    BTN_W    = 75.0
    BTN_H    = 23.0
    PAD      = 16.0
    # Gap between the SideImage column and the step content.
    SIDE_GAP = 16.0

    # Sizing: the card aims at SCREEN_SHARE of the host window (~the
    # window minus 10%), never below MIN_CARD, capped at the window.
    SCREEN_SHARE = 0.9
    MIN_CARD     = Vec2.new(640.0, 520.0)
    # Banner + footer + body insets — subtracted from the target card
    # height to floor the body area.
    CHROME_H     = 160.0

    # One footer button: a ROLE (back/next/finish/cancel — the Wizard
    # itself acts on it) or :custom (an app action). `label` overrides
    # the Wizard's default text for the role; custom buttons require
    # one. `enabled` grays the button out (a dead Response — no click).
    class Button
      enum Kind
        Back
        Next
        Finish
        Cancel
        Custom
      end

      getter kind : Kind
      getter label : String?
      getter action : (Wizard -> Nil)?
      property? enabled : Bool = true

      def initialize(@kind : Kind, @label : String? = nil,
                     @action : (Wizard -> Nil)? = nil, enabled : Bool = true)
        @enabled = enabled
      end

      def self.back(label : String? = nil) : Button
        new(Kind::Back, label)
      end

      def self.next(label : String? = nil) : Button
        new(Kind::Next, label)
      end

      def self.finish(label : String? = nil) : Button
        new(Kind::Finish, label)
      end

      def self.cancel(label : String? = nil) : Button
        new(Kind::Cancel, label)
      end

      # An app-defined button; the block receives the Wizard.
      def self.custom(label : String, &action : Wizard -> Nil) : Button
        new(Kind::Custom, label, action)
      end
    end

    getter steps : Array(WizardStep)
    getter index : Int32
    getter? finished : Bool
    getter? cancelled : Bool

    # Footer label defaults (per-step `next_label`/`finish_label`
    # override the middle two).
    property back_label : String = "Back"
    property next_label : String = "Next"
    property finish_label : String = "Finish"
    property cancel_label : String = "Cancel"

    @on_finish : (Wizard -> Nil)? = nil
    @on_cancel : (Wizard -> Nil)? = nil
    @shown_index : Int32 = -1
    # This frame's body-area height (derived in #show from the host
    # window, ~90% of it minus the chrome) — the card is proportional
    # on BOTH axes and identical across steps; draw_body reads it.
    @body_floor = 240.0

    # `width`/`min_body_height`: nil (the default) = auto — ~90% of
    # the host window (see #show); a number pins that axis.
    def initialize(@title : String, @steps : Array(WizardStep),
                   @width : Float64? = nil, @id : String = "wizard",
                   @min_body_height : Float64? = nil)
      @index = 0
      @finished = false
      @cancelled = false
    end

    # Fired when the last step's Finish is clicked (after the step's
    # own `on_next`); the wizard is `finished?` from then on.
    def on_finish(&block : Wizard -> Nil) : Nil
      @on_finish = block
    end

    # Fired on the Cancel button, before the wizard turns `cancelled?`.
    def on_cancel(&block : Wizard -> Nil) : Nil
      @on_cancel = block
    end

    def current_step : WizardStep
      @steps[@index]
    end

    # Navigation. `next!`/`back!` clamp at the ends; `finish!` and
    # `cancel!` set the terminal flags `#show` reports.
    def next! : Nil
      @index += 1 if @index < @steps.size - 1
    end

    def back! : Nil
      @index -= 1 if @index > 0
    end

    def finish! : Nil
      @finished = true
    end

    def cancel! : Nil
      @cancelled = true
    end

    # Back to the start, flags cleared (run another round).
    def reset! : Nil
      @index = 0
      @finished = false
      @cancelled = false
      @shown_index = -1
    end

    # Draw the wizard (call every frame while open). True the frame the
    # user is DONE with it — finished, cancelled, or closed via the ✕ —
    # so the usual host loop is
    # `@open = false if @open && wizard.show(ctx)`.
    #
    # Sizing (see SCREEN_SHARE/MIN_CARD): ~90% of the host window on
    # BOTH axes — the card is proportional to the window and identical
    # across steps; a step taller than the body area scrolls instead
    # of growing the card.
    def show(ctx : Context) : Bool
      return true if @steps.empty?
      host = ctx.input.screen_rect.size
      width = @width || {host.x * SCREEN_SHARE, MIN_CARD.x}.max
      width = {width, host.x}.min
      @body_floor = @min_body_height ||
        {host.y * SCREEN_SHARE - CHROME_H, 240.0}.max
      closed = ctx.embedded_window(@id, title: @title, width: width) do |ui|
        ui.with_style_scope(ROOT_CLASS) { draw(ui) }
      end
      closed || @finished || @cancelled
    end

    # --- layout ------------------------------------------------------------

    private def draw(ui : Ui) : Nil
      step = current_step
      fire_on_show(step)
      draw_banner(ui, step)
      draw_body(ui, step)
      draw_footer(ui, step)
    end

    # A step becoming current fires its `on_show` once (not every
    # frame) — the template's "enter step" action.
    private def fire_on_show(step : WizardStep) : Nil
      if @shown_index != @index
        @shown_index = @index
        step.on_show.try(&.call(self))
      end
    end

    private def draw_banner(ui : Ui, step : WizardStep) : Nil
      banner = ui.allocate_space(Vec2.new(ui.available_width, BANNER_H))
      sheet = ui.ctx.stylesheet
      vars = sheet.resolve(HEADER_CLASS)
      v = ui.style.visuals
      fill = vars.color("background",
        v.window_fill.lerp(v.text_color, 0.05))
      title_color = vars.color("text_color", v.text_color)
      sub_color = vars.color("subtitle_color",
        v.text_color.lerp(v.window_fill, 0.35))
      p = ui.painter
      p.rect(banner, 0.0, fill: fill)
      p.line(Pos2.new(banner.left, banner.bottom - 0.5),
        Pos2.new(banner.right, banner.bottom - 0.5), 1.0, v.separator_color)

      fs = ui.style.font_size
      if step.subtitle.empty?
        p.text(Pos2.new(banner.left + PAD, banner.center.y),
          step.title, fs * 1.3, title_color, bold: true)
      else
        p.text(Pos2.new(banner.left + PAD, banner.top + 24.0),
          step.title, fs * 1.3, title_color, bold: true)
        p.text(Pos2.new(banner.left + PAD, banner.top + 46.0),
          step.subtitle, fs, sub_color)
      end
    end

    private def draw_body(ui : Ui, step : WizardStep) : Nil
      ui.allocate_space(Vec2.new(0.0, 14.0))
      h = @body_floor
      # The watermark column: full body height — known up front, the
      # card being window-proportional (not content-sized).
      if (side = step.side_image)
        side.paint(ui, Rect.from_min_size(
          Pos2.new(ui.cursor.x + PAD, ui.cursor.y),
          Vec2.new(side.width, h)))
      end
      side_w = step.side_image ? step.side_image.not_nil!.width + SIDE_GAP : 0.0
      # Step content in a scroll area capped at the body height: the
      # card NEVER reflows with content (a taller step scrolls, it
      # does not grow the dialog), so the geometry stays proportional
      # to the host window on both axes and identical across steps.
      cell_w = {ui.available_width - 2 * PAD - side_w, 1.0}.max
      cell = ui.child_ui(Rect.from_min_size(
        Pos2.new(ui.cursor.x + PAD + side_w, ui.cursor.y),
        Vec2.new(cell_w, h)))
      ScrollArea.new(max_height: h, id: Id.from("#{@id}_body_#{@index}"))
        .show(cell) { |scroll| step.body.call(scroll) }
      ui.allocate_space(Vec2.new(0.0, h))
      ui.allocate_space(Vec2.new(0.0, 14.0))
    end

    private def draw_footer(ui : Ui, step : WizardStep) : Nil
      sep = ui.allocate_space(Vec2.new(ui.available_width, 1.0))
      ui.painter.line(Pos2.new(sep.left, sep.top + 0.5),
        Pos2.new(sep.right, sep.top + 0.5), 1.0,
        ui.style.visuals.separator_color)
      ui.allocate_space(Vec2.new(0.0, 10.0))

      ui.horizontal(wrap: false) do |row|
        btns = footer_buttons(step)
        # Right-align: reserve the slack before the first button. The
        # estimate MUST be Button#ui's exact natural-width formula
        # (text + button padding, + glyph-height icon and icon gap for
        # the chevron buttons, floored at the 75pt Win32 min) — any
        # per-button guesswork would move the row's right edge with
        # the step's button COUNT, and the buttons would "swim"
        # between steps.
        fs = row.style.font_size
        bp = row.style.spacing.button_padding
        icon_gap = row.style.spacing.icon_spacing
        total = btns.sum do |b|
          text_size = row.fonts.measure_cached(label_for(step, b), fs)
          w = text_size.x + 2 * bp.x
          w += text_size.y + icon_gap if chevroned?(b)
          {w, BTN_W}.max
        end
        total += (btns.size - 1) * row.style.spacing.item_spacing.x
        slack = row.available_width - total -
          row.style.spacing.item_spacing.x
        row.allocate_space(Vec2.new({slack, 0.0}.max, 0.0))
        btns.each_with_index { |b, i| footer_button(row, step, b, i) }
      end
    end

    # Back/Next carry the chevron glyphs (‹ Back, Next ›) as embedded
    # lucide SVGs; Finish and custom buttons stay text-only.
    private def chevroned?(btn : Button) : Bool
      btn.kind.back? || btn.kind.next?
    end

    # The step's footer: its own `buttons` list verbatim, or the
    # standard set for its position (back from step 2 on, next/finish,
    # cancel — each hideable per step).
    private def footer_buttons(step : WizardStep) : Array(Button)
      if list = step.buttons
        list
      else
        out = [] of Button
        out << Button.back if @index > 0 && step.show_back?
        out << (last_step? ? Button.finish : Button.next)
        out << Button.cancel if step.show_cancel?
        out
      end
    end

    private def footer_button(ui : Ui, step : WizardStep, btn : Button,
                              i : Int32) : Nil
      gated = btn.kind.next? || btn.kind.finish? ? gate_open?(step) : true
      active = btn.enabled? && gated
      id = btn.kind.custom? ? "#{@id}_custom_#{i}" : "#{@id}_#{btn.kind.to_s.downcase}"
      # The disabled gate goes through Memory#push_disabled (the same
      # machinery Ui#enabled uses) so the button stays a FLAT widget of
      # the footer row — Ui#enabled wraps it in a vertical child Ui,
      # which would break the single-row layout.
      ui.ctx.memory.push_disabled unless active
      widget = ::Egui::Button.new(label_for(step, btn), id: id)
        .min_size(Vec2.new(BTN_W, BTN_H))
      tint = ui.style.visuals.text_color
      case btn.kind
      when .back?
        widget.icon(Icon.from_file(:lucide, :chevron_left, tint: tint))
      when .next?
        widget.icon_trailing(Icon.from_file(:lucide, :chevron_right, tint: tint))
      end
      resp = ui.add(widget)
      ui.ctx.memory.pop_disabled unless active
      if active && (r = resp) && r.clicked?
        case btn.kind
        in .back?
          step.on_back.try(&.call(self))
          back!
        in .next?
          step.on_next.try(&.call(self))
          next!
        in .finish?
          step.on_next.try(&.call(self))
          finish!
          @on_finish.try(&.call(self))
        in .cancel?
          cancel!
          @on_cancel.try(&.call(self))
        in .custom?
          btn.action.try(&.call(self))
        end
      end
    end

    # The Next/Finish gate: the step's `can_next` block, true when the
    # step declares none.
    private def gate_open?(step : WizardStep) : Bool
      (gate = step.can_next) ? gate.call(self) : true
    end

    private def label_for(step : WizardStep, btn : Button) : String
      case btn.kind
      in .back?    then btn.label || @back_label
      in .next?    then btn.label || step.next_label || @next_label
      in .finish?  then btn.label || step.finish_label || @finish_label
      in .cancel?  then btn.label || @cancel_label
      in .custom?  then btn.label.not_nil!
      end
    end

    private def last_step? : Bool
      @index == @steps.size - 1
    end
  end

  # One wizard page — see Wizard's doc for the template. The body
  # block renders into a padded child Ui (any widgets); the footer is
  # the standard button set unless `buttons` replaces it wholesale:
  #
  #   step.buttons = [
  #     Egui::Wizard::Button.custom("Run") { |w| w.next! },
  #     Egui::Wizard::Button.cancel,
  #   ]
  class WizardStep
    getter title : String
    getter subtitle : String
    getter body : Ui -> Nil

    # nil → the standard footer for this step's position; a full
    # replacement list, rendered in order, left to right.
    property buttons : Array(Wizard::Button)? = nil

    # The watermark column (SideImage) — an image strip on the LEFT of
    # the body: capped width, height follows the step's content.
    property side_image : SideImage? = nil

    # Standard-set tweaks: hide Back/Cancel on this step, re-label
    # Next/Finish ("Install >" instead of "Next >").
    property? show_back : Bool = true
    property? show_cancel : Bool = true
    property next_label : String? = nil
    property finish_label : String? = nil

    @on_next : (Wizard -> Nil)? = nil
    @on_back : (Wizard -> Nil)? = nil
    @on_show : (Wizard -> Nil)? = nil
    @can_next : (Wizard -> Bool)? = nil

    def initialize(@title : String, @subtitle : String = "", &@body : Ui ->)
    end

    # Runs when Next (or Finish on the last step) is clicked, BEFORE
    # the wizard advances — side effects live here.
    def on_next(&block : Wizard -> Nil) : Nil
      @on_next = block
    end

    # Runs when Back is clicked, before the wizard moves back.
    def on_back(&block : Wizard -> Nil) : Nil
      @on_back = block
    end

    # Runs once when this step becomes the current one.
    def on_show(&block : Wizard -> Nil) : Nil
      @on_show = block
    end

    # While false the Next/Finish button is disabled — the validation
    # gate ("can't continue until the form is filled").
    def can_next(&block : Wizard -> Bool) : Nil
      @can_next = block
    end

    def on_next : (Wizard -> Nil)?
      @on_next
    end

    def on_back : (Wizard -> Nil)?
      @on_back
    end

    def on_show : (Wizard -> Nil)?
      @on_show
    end

    def can_next : (Wizard -> Bool)?
      @can_next
    end
  end
end
