# egui.cr-native (no upstream counterpart): GTK `GtkAboutDialog`
# pattern — program metadata laid out in a WindowModal:
# logo (optional texture), program name, version, comments, website
# (a live hyperlink), authors, copyright; a single Close button.
#
#   about = Egui::AboutModal.new("about", "My App")
#   about.version = "1.2.3"
#   about.website_url = "https://example.com"
#   about.authors = ["Alice", "Bob"]
#   about.show(ctx)

module Egui
  class AboutModal < WindowModal
    BTN_CLOSE = 0x210_u64

    property program_name : String
    property logo : UInt64 # texture id (0 = none)
    property version : String?
    property copyright : String?
    property comments : String?
    property website_url : String?
    property website_label : String?
    property authors : Array(String)

    def initialize(id : String, @program_name : String,
                   title : String = "About", width : Float64 = 380.0)
      super(id, title, width)
      @logo = 0_u64
      @authors = [] of String
    end

    def body(ctx : Context, ui : Ui) : Nil
      v = ui.style.visuals
      if @logo != 0
        ui.image(@logo, Vec2.new(72.0, 72.0))
      end
      # GTK lays the About dialog out centered: name, version,
      # comments and website on the middle axis; the authors list and
      # copyright below (block text alignment — CSS `text-align`).
      ui.rich(RichText.new(@program_name)
        .heading(ui.style.font_size).align(:center))
      if @version
        ui.rich(RichText.new("Version #{@version}")
          .small(ui.style.font_size).weak(v).align(:center))
      end
      if (c = @comments) && !c.empty?
        ui.separator
        ui.label(c, wrap: true, align: :center)
      end
      if (url = @website_url) && !url.empty?
        ui.hyperlink_to(@website_label || url, url, align: :center)
      end
      unless @authors.empty?
        ui.separator
        ui.label("Authors", align: :center)
        @authors.each { |a| ui.label("- #{a}") }
      end
      if (c = @copyright) && !c.empty?
        ui.separator
        ui.rich(RichText.new(c).weak(v).align(:center))
      end
    end

    def buttons(ctx : Context, ui : Ui) : Nil
      close(ctx) if button_row(ui,
        [{modal_id.child(BTN_CLOSE), "Close"}]).first
    end
  end
end
