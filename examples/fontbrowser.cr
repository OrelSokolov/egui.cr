# Font specimen browser — the fonts.google.com/noto/specimen layout:
# type a preview string, dial the size (slider + preset dropdown), pick a
# family from the searchable catalog, and every style file of that family
# renders the string in a row of its own. Discovery (family folding,
# weight-axis parsing, per-file deferred stacks) is the ENGINE's
# `Egui::FontCuts` — the same module the CSS font-weight cascade and the
# inspector's smart selector resolve through; this example is a pure
# view over it.

require "../src/egui/backend_selector"
require "../src/egui/backend/crystalfonts"

class FontBrowserApp < Egui::App
  # Dropdown presets alongside the free slider (both write @size).
  SIZES = [12.0, 16.0, 20.0, 24.0, 32.0, 48.0, 64.0, 96.0]

  @text = "reactive"
  @size = 32.0
  @family = ""
  @dark = true
  @applied_theme : Bool? = nil
  # family name → every style file found for it (several dirs can merge).
  @families = {} of String => Array(String)
  # Active family's rows: style label → file path.
  @variants = [] of {String, String}
  @variants_family = ""

  def initialize
    super
    # The engine scan: normalized families (the "Noto Sans Thin" files
    # fold onto "Noto Sans") with every cut parsed off the filename
    # token — see Egui::FontCuts.
    @families = Egui::FontCuts.installed
      .transform_values(&.map(&.path))
    names = @families.keys.sort
    # The reference specimen (the Google Fonts default): Noto Sans when
    # installed, otherwise the first family the scan found.
    @family = names.find { |n| n == "Noto Sans" } || names.first? || ""
  end

  def update(ctx : Egui::Context) : Nil
    # Theme swap on change only — re-assigning every frame would
    # rebuild the preset and drop any runtime style state.
    unless @applied_theme == @dark
      ctx.theme = @dark ? Egui::Theme.dark : Egui::Theme.light
      @applied_theme = @dark
    end

    ctx.central_panel do |ui|
      # Controls stay pinned above the scroll area (it takes only the
      # remaining height): preview text, size slider + preset dropdown,
      # searchable family picker.
      ui.horizontal do |row|
        row.label("Preview text")
        row.text_edit_singleline(@text, hint: "type to preview…") { |t| @text = t }
        # Theme swap — the whole UI repaints next frame (widgets
        # re-read the theme style every frame, see theme.cr).
        row.combo_box("fb_theme", @dark ? "Dark" : "Light", %w(Dark Light)) do |opt|
          @dark = opt == "Dark"
        end
      end
      ui.horizontal do |row|
        # A bare Slider stretches to the row's full remaining width
        # (Spacing#slider_width is only a MINIMUM) and would push the
        # dropdown and the family picker off-screen — box it instead.
        # Values snap to whole pixels (the label shows them raw).
        resp = row.add_sized(
          Egui::Vec2.new(240.0, row.style.spacing.interact_size.y),
          Egui::Slider.new(@size, 8.0..96.0, "Size"))
        if resp.changed? && (v = resp.widget_value)
          @size = v.round
        end
        row.combo_box("fb_size", "#{@size.to_i} px",
          SIZES.map { |s| "#{s.to_i} px" }) do |opt|
          @size = opt.rpartition(' ').first.to_f
        end
        row.label("Family")
        row.select_box("fb_family", @family, @families.keys.sort, 240.0) do |f|
          @family = f
        end
      end
      ui.separator

      rebuild_variants
      ui.scroll_area do |scroll|
        scroll.heading(@family)
        files = @families[@family]? || [] of String
        scroll.rich(Egui::RichText
          .new("#{files.size} style file#{files.size == 1 ? "" : "s"}")
          .small(scroll.style.font_size).weak(scroll.style.visuals))
        scroll.separator
        @variants.each do |label, path|
          stack = ctx.cut_stack(path)
          scroll.rich(Egui::RichText.new(label)
            .small(scroll.style.font_size).weak(scroll.style.visuals))
          # Route just the specimen through this style's stack; the
          # chrome (labels, scrollbars) stays on the UI font.
          ctx.style.font_family = stack
          text = @text.empty? ? label : @text
          scroll.rich(Egui::RichText.new(text).size(@size))
          ctx.style.font_family = nil
          scroll.separator
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # Variant rows (the engine's parsed cuts)

  # Refresh @variants when the picked family changed: the engine's
  # per-family cut list is already ordered weight-axis first
  # (100→900, roman before slanted), the width/shape cuts after it.
  private def rebuild_variants : Nil
    return if @variants_family == @family
    @variants_family = @family
    @variants = (Egui::FontCuts.installed[@family]? || [] of Egui::FontCuts::Cut)
      .map { |cut| {cut.label, cut.path} }
  end
end

Egui.run(FontBrowserApp.new, title: "egui-cr — fonts",
  width: 1024, height: 800, inspector: :hidden)
