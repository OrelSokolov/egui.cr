# Form validation — the HTML constraint layer (form.cr): `required`,
# `pattern`, the `:invalid` state and the gated submit.
#
#   ui.form("signup") do |ui, form|
#     ui.input(name, required: true) { |t| name = t }
#     form.submit_button("Create account") { … }   # fires only when all fields pass
#   end
#
# Semantics ported from the browser (no server to submit to — the
# block IS the submit handler):
# - an invalid field paints `text_edit:invalid` only once TOUCHED
#   (typed into, or focus given up) — a pristine form doesn't scream;
# - a blocked submit marks the form ATTEMPTED: every invalid field
#   reveals its error at once, like the browser's submit-time pass;
# - `pattern` judges non-empty values only; empties are `required`'s
#   concern (HTML constraint validation rules);
# - focusing a live-invalid field pops the validation bubble under
#   it — Chrome's :invalid tooltip, standard texts ("Please fill out
#   this field" / "Please match the requested format"), no delay.
#
# The danger stroke comes from the default theme's
# `text_edit:invalid` rule — restyle it in ECSS like any state:
#   text_edit:invalid { stroke: #b00020; }
#
# The browser twin (native required/pattern for side-by-side looks)
# is examples/form_validation.html.

require "../src/egui/driver_selector"
require "../src/egui/html"

class FormValidationApp < Egui::App
  EMAIL_RE = /[^@]+@[^@]+/
  PHONE_RE = /^[0-9 +()-]+$/

  @name = ""
  @email = ""
  @phone = ""
  @submitted : String? = nil

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("Create an account")
      ui.label("Required fields gate the submit; the phone field is " \
               "optional (pattern judges non-empty values only).")

      ui.form("signup") do |ui, form|
        field(ui, "Name *", placeholder: "Ada Lovelace",
          required: true, buffer: @name) { |t| @name = t }
        field(ui, "Email *", placeholder: "ada@example.com",
          required: true, pattern: EMAIL_RE.source,
          buffer: @email) { |t| @email = t }
        field(ui, "Phone", placeholder: "+1 555 0100",
          pattern: PHONE_RE.source, buffer: @phone) { |t| @phone = t }

        ui.separator
        form.submit_button("Create account") do
          @submitted = "Account created for #{@name} <#{@email}>" \
                       "#{@phone.empty? ? "" : " (#{@phone})"}"
        end

        # Post-submit status: a blocked attempt reveals every error at
        # once (attempted), a fired one shows the receipt.
        bad = form.inputs.count { |_id, invalid| invalid }
        if (msg = @submitted)
          ui.label(msg)
        elsif form.attempted? && bad > 0
          ui.label("#{bad} field#{bad == 1 ? "" : "s"} need attention")
        end
      end
    end
  end

  # One label + input row. The `pattern:` attr is a STRING (the html
  # alias compiles it — a bad regex raises immediately, app-side bug).
  private def field(ui : Egui::Ui, caption : String, *, buffer : String,
                    placeholder : String, required : Bool = false,
                    pattern : String? = nil, &on_change : String ->) : Nil
    ui.horizontal do |h|
      h.label(caption)
      h.input(buffer, placeholder: placeholder, required: required,
        pattern: pattern, width: 260.0) { |t| on_change.call(t) }
    end
  end
end

Egui.run(FormValidationApp.new, title: "egui.cr — form validation")
