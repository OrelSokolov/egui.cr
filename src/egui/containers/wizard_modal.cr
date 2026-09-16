# egui.cr-native (no upstream counterpart): GTK `GtkAssistant`
# pattern — a multi-page wizard modal. The current page persists in
# IdTypeMap while the dialog is open and resets to 0 on #open; each
# frame the page block renders the requested page:
#
#   Egui::WizardModal.new("setup", "Setup Wizard", 3) do
#     @configured = true
#   end.show(ctx) do |ui, page|
#     case page
#     when 0 then ui.label("Welcome …")
#     when 1 then ui.label("Choose preferences …")
#     when 2 then ui.label("Ready to finish …")
#     end
#   end
#
# The button strip is GTK's: Cancel | Back | Next, with Back disabled
# on the first page and Next turning into Finish on the last one
# (Finish fires the constructor block and closes).

module Egui
  class WizardModal < WindowModal
    PAGE       = 0x210_u64
    BTN_CANCEL = 0x220_u64
    BTN_BACK   = 0x221_u64
    BTN_NEXT   = 0x222_u64

    getter page_count : Int32
    property back_label : String
    property next_label : String
    property cancel_label : String
    property finish_label : String

    @on_finish : ->
    @page_block : (Ui, Int32 ->)?

    def initialize(id : String, title : String, @page_count : Int32,
                   width : Float64 = 460.0, &@on_finish : ->)
      super(id, title, width)
      @back_label = "Back"
      @next_label = "Next"
      @cancel_label = "Cancel"
      @finish_label = "Finish"
    end

    # Wizards always start over from the first page.
    def on_open(ctx : Context) : Nil
      ctx.memory.data.set_int(modal_id.child(PAGE), 0)
    end

    def page(ctx : Context) : Int32
      ctx.memory.data.get_int(modal_id.child(PAGE), 0)
        .clamp(0, @page_count - 1)
    end

    def last_page?(ctx : Context) : Bool
      page(ctx) == @page_count - 1
    end

    # The page-content entry point; pages render on the body Ui.
    def show(ctx : Context, &page : Ui, Int32 ->) : Nil
      @page_block = page
      super(ctx)
    end

    def body(ctx : Context, ui : Ui) : Nil
      p = page(ctx)
      ctx.memory.use_id(modal_id.child(PAGE))
      ui.rich(RichText.new("Step #{p + 1} of #{@page_count}")
        .weak(ui.style.visuals).align(:center))
      ui.separator
      @page_block.try(&.call(ui, p))
    end

    def buttons(ctx : Context, ui : Ui) : Nil
      mid = modal_id
      p = page(ctx)
      last = last_page?(ctx)
      disabled = p == 0 ? [mid.child(BTN_BACK)] of Id : [] of Id
      clicks = button_row(ui, [
        {mid.child(BTN_CANCEL), @cancel_label},
        {mid.child(BTN_BACK), @back_label},
        {mid.child(BTN_NEXT), last ? @finish_label : @next_label},
      ], disabled)

      if clicks[0] # Cancel
        close(ctx)
      elsif clicks[1]
        ctx.memory.data.set_int(mid.child(PAGE), p - 1)
      elsif clicks[2]
        if last
          close(ctx)
          @on_finish.call
        else
          ctx.memory.data.set_int(mid.child(PAGE), p + 1)
        end
      end
    end
  end
end
