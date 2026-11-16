# `<form>` — the HTML form, minus the server: submission here is a
# local block, so what remains of a form is its real contract —
# associating the inputs of a subtree with one submit gate:
#
#   ui.form("login") do |ui, form|
#     ui.text_edit_singleline(email, required: true, pattern: EMAIL_RE) { |t| email = t }
#     form.submit_button("Sign in") { sign_in(email) }   # fires only when valid
#   end
#
# The element itself paints nothing and lays out nothing — children
# flow in the parent (the browser's `<form>` is a plain block too).
# Inputs register their per-frame validity as they render (through
# `Context#current_form_id`), in DOM order — a submit button must
# FOLLOW its fields in the tree, the same order rule the browser has.
#
# A blocked click marks the form ATTEMPTED (`Context#mark_form_attempted`,
# sticky per form id): every invalid field then shows its `:invalid`
# state even if the user never touched it — the browser's submit-time
# validity pass. Values are NOT collected: the app already owns the
# buffers (immediate mode — inputs edit the app's strings in place).
module Egui
  class Form
    getter id : Id

    def initialize(@ui : Ui, @id : Id)
    end

    # Every registered input valid this frame? (An empty registry is
    # valid — a form of no inputs submits trivially.)
    def valid? : Bool
      !@ui.ctx.form_inputs_invalid?(@id)
    end

    # A submit was blocked at least once (sticky — errors stay
    # revealed until each field turns valid).
    def attempted? : Bool
      @ui.ctx.form_attempted?(@id)
    end

    # This frame's registrations: {input id, invalid} in DOM order —
    # handy for a "N fields need attention" line.
    def inputs : Array({Id, Bool})
      @ui.ctx.form_inputs(@id)
    end

    # The submit button: a click on a VALID form fires the block and
    # returns true; a click on an invalid one marks the form attempted
    # (fields reveal their errors, browser semantics) and returns
    # false. No click → false, block not called.
    def submit_button(text : String, id : String? = nil,
                      &on_submit) : Bool
      clicked = @ui.button(text, id: id).clicked?
      return false unless clicked
      if valid?
        yield
        true
      else
        @ui.ctx.mark_form_attempted(@id)
        false
      end
    end
  end
end
