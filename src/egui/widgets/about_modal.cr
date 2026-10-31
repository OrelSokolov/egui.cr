# An About dialog: a WIDE modal (640pt vs the standard 480) whose body
# is a rendered Markdown document in a scroll area — the classic
# "About this app" screen (name / version / description / credits)
# without the caller building any of it. A long document scrolls
# instead of growing the card past the screen; short content keeps
# the card compact (the scroll area only caps, it never stretches).
#
#   @about = Egui::AboutModal.new("About my app", MD_TEXT)
#   # while open, every frame:
#   @about_open = false if @about.show(ctx)

module Egui
  class AboutModal
    # The standard #modal is 480pt wide; the About screen is a
    # document, so it gets a wider default.
    DEFAULT_WIDTH = 640.0
    # Body cap: the scroll viewport never exceeds this share of the
    # screen height (title + footer add on top of it).
    BODY_SCREEN_SHARE = 0.6

    def initialize(@title : String, @markdown : String,
                   @width : Float64 = DEFAULT_WIDTH, @id : String = "about")
    end

    # Draw the dialog (call every frame while open). True the frame
    # the user closed it — the Close button or a click on the scrim.
    # The markdown page follows the CARD's window_fill (not the
    # reader-page default) so the body merges with the dialog — no
    # seam between the page and the card around it.
    def show(ctx : Context) : Bool
      closed = false
      page = ctx.style.visuals.window_fill
      clicked = ctx.modal(@id, width: @width, title: @title,
        buttons: ["Close"],
        on_scrim_click: ->{ closed = true; nil }) do |ui|
        cap = ctx.input.screen_rect.height * BODY_SCREEN_SHARE
        ScrollArea.new(max_height: cap).show(ui) do |scroll|
          scroll.add(Egui::Markdown.new(@markdown, id: "#{@id}_md",
            background: page))
        end
      end
      closed || clicked == "Close"
    end
  end
end
