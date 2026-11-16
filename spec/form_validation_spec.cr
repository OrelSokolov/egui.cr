require "spec"
require "../src/egui"
require "../src/egui/html"

# Form validation MVP (form.cr): `required`/`pattern` on text fields,
# the `:invalid` style state, and the `<form>` submit gate.
#
#   ui.form("f") do |ui, form|
#     ui.input(email, required: true) { |t| email = t }
#     form.submit_button("Save") { submitted = true }   # gated
#   end
#
# HTML semantics ported: an invalid field only SHOWS its error once
# touched (edited, or focus given up) or after a blocked submit; the
# submit fires only when every registered field is valid; a blocked
# click marks the form attempted (sticky). Values are never collected
# — the app owns the buffers; the form is scope + gate, nothing else.

FORM_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(800.0, 600.0))

# The validation bubble (Chrome's :invalid tooltip): pops under the
# FOCUSED field, no hover delay, while its error state is live. The
# bubble's standard texts appear nowhere else in the app, so scanning
# the frame's text commands for them is a faithful probe.
def bubble_texts(ctx : Egui::Context) : Array(String)
  ctx.painter.commands.select(Egui::TextCmd).map(&.text)
end

class FormApp
  property email = ""
  property name = ""
  property submitted = 0
  property name_resp : Egui::Response? = nil
  property email_resp : Egui::Response? = nil

  def update(ctx : Egui::Context, events : Array(Egui::Event) = [] of Egui::Event) : Nil
    ctx.begin_frame(Egui::RawInput.new(FORM_SCREEN, events, 0.016))
    ctx.central_panel do |ui|
      ui.form("f") do |ui, form|
        @name_resp = ui.input(name, required: true,
          placeholder: "Name") { |t| @name = t }
        @email_resp = ui.input(email, required: true,
          pattern: "[^@]+@[^@]+") { |t| @email = t }
        form.submit_button("Save") { @submitted += 1 }
      end
    end
    ctx.end_frame
  end

  # The submit button's rect — the LAST widget registered in the form
  # frame (the button renders after its fields, DOM order).
  def button_rect(ctx : Egui::Context) : Egui::Rect
    ctx.memory.widget_rects.to_a.last[1]
  end
end

describe "form validation" do
  it "required: an untouched empty field is invalid but does not show it" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx) # second frame: geometry known, still untouched
    # The error display (the response's invalid flag — the `:invalid`
    # style state behind it) waits for a touch or a blocked submit.
    app.name_resp.not_nil!.invalid?.should be_false
    app.email_resp.not_nil!.invalid?.should be_false
  end

  it "pattern: a mismatched value shows invalid after typing" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx) # frame 1: layout
    app.update(ctx) # frame 2: stable geometry
    # Focus the email field (a click), then type into it — focus
    # types from the next frame on.
    center = app.email_resp.not_nil!.rect.center
    app.update(ctx, [Egui::Event.pointer_pressed(center),
                     Egui::Event.pointer_released(center)])
    app.update(ctx, [Egui::Event.text_input("nope")])
    app.email.should eq("nope")
    app.email_resp.not_nil!.invalid?.should be_true
    # a well-formed address clears it
    app.update(ctx, [Egui::Event.text_input("x@y")])
    app.email_resp.not_nil!.invalid?.should be_false
  end

  it "required: an emptied value shows invalid after typing and clearing" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx)
    center = app.name_resp.not_nil!.rect.center
    app.update(ctx, [Egui::Event.pointer_pressed(center),
                     Egui::Event.pointer_released(center)])
    app.update(ctx, [Egui::Event.text_input("a")])
    app.update(ctx, [Egui::Event.key_pressed(:backspace)])
    app.name.should eq("")
    app.name_resp.not_nil!.invalid?.should be_true
  end

  it "submit is blocked while any field is invalid, and the attempt reveals errors" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx)
    btn = app.button_rect(ctx)
    app.update(ctx, [Egui::Event.pointer_pressed(btn.center),
                     Egui::Event.pointer_released(btn.center)])
    app.update(ctx)
    app.submitted.should eq(0) # blocked: the required name is empty
    # the blocked attempt revealed the required-name error
    app.name_resp.not_nil!.invalid?.should be_true
    ctx.form_attempted?(Egui::Id.from("f")).should be_true
  end

  it "submit fires when every field is valid" do
    app = FormApp.new
    app.name = "Ada"
    app.email = "ada@example.com"
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx)
    btn = app.button_rect(ctx)
    app.update(ctx, [Egui::Event.pointer_pressed(btn.center),
                     Egui::Event.pointer_released(btn.center)])
    app.submitted.should eq(1)
  end

  it "fields outside a form never register (no gate without a form)" do
    ctx = Egui::Context.new
    ctx.begin_frame(Egui::RawInput.new(FORM_SCREEN, [] of Egui::Event, 0.016))
    ctx.central_panel do |ui|
      ui.input("x", required: true) { |_| }
    end
    ctx.end_frame
    ctx.current_form_id.should be_nil
    ctx.form_inputs(Egui::Id.from("f")).should be_empty
  end

  it "shows the required bubble on a focused invalid empty field" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx)
    # Focus the name field (required, empty) — untouched: no bubble.
    center = app.name_resp.not_nil!.rect.center
    app.update(ctx, [Egui::Event.pointer_pressed(center),
                     Egui::Event.pointer_released(center)])
    bubble_texts(ctx).should_not contain("Please fill out this field") # pristine
    # Type one char and clear it: touched, empty, focused → bubble.
    app.update(ctx, [Egui::Event.text_input("a")])
    app.update(ctx, [Egui::Event.key_pressed(:backspace)])
    bubble_texts(ctx).should contain("Please fill out this field")
    # Filled: the bubble disappears.
    app.update(ctx, [Egui::Event.text_input("Ada")])
    bubble_texts(ctx).should_not contain("Please fill out this field")
  end

  it "shows the pattern bubble on a focused mismatched field" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx)
    center = app.email_resp.not_nil!.rect.center
    app.update(ctx, [Egui::Event.pointer_pressed(center),
                     Egui::Event.pointer_released(center)])
    app.update(ctx, [Egui::Event.text_input("nope")])
    bubble_texts(ctx).should contain("Please match the requested format")
  end

  it "hover alone never pops the bubble — focus only" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx)
    # Touch the name field, clear it (touched + invalid, error shown),
    # then drop focus with Escape and merely HOVER the field.
    center = app.name_resp.not_nil!.rect.center
    app.update(ctx, [Egui::Event.pointer_pressed(center),
                     Egui::Event.pointer_released(center)])
    app.update(ctx, [Egui::Event.text_input("a")])
    app.update(ctx, [Egui::Event.key_pressed(:backspace)])
    app.update(ctx, [Egui::Event.key_pressed(:escape)])
    app.update(ctx, [Egui::Event.pointer_moved(center)])
    app.update(ctx)
    app.name_resp.not_nil!.invalid?.should be_true # error still shown
    bubble_texts(ctx).should_not contain("Please fill out this field")
    # Focusing it again brings the bubble back.
    app.update(ctx, [Egui::Event.pointer_pressed(center),
                     Egui::Event.pointer_released(center)])
    app.update(ctx)
    bubble_texts(ctx).should contain("Please fill out this field")
  end

  it "a blocked submit reveals errors; focusing the field pops the bubble" do
    app = FormApp.new
    ctx = Egui::Context.new
    app.update(ctx)
    app.update(ctx)
    btn = app.button_rect(ctx)
    app.update(ctx, [Egui::Event.pointer_pressed(btn.center),
                     Egui::Event.pointer_released(btn.center)])
    app.submitted.should eq(0) # blocked: the required name is empty
    # The click surrendered the field's focus; the attempt revealed
    # the red borders. Focusing the invalid field pops its bubble.
    center = app.name_resp.not_nil!.rect.center
    app.update(ctx, [Egui::Event.pointer_pressed(center),
                     Egui::Event.pointer_released(center)])
    app.update(ctx)
    bubble_texts(ctx).should contain("Please fill out this field")
  end
end
