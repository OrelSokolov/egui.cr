# font_lab — the font probes in one window (the merge of the former
# fontbrowser / fontpreview examples; the mdvsfonts metric-twins probe
# is gone — the markdown widget renders through the same font
# elements now), a tab per view:
#
#   Specimen  — the fonts.google.com/noto/specimen layout: preview
#               text, size dial (slider + presets), searchable family
#               picker; every style file of the family renders the
#               string in a row of its own. Discovery (family
#               folding, weight-axis parsing, per-file deferred
#               stacks) is the ENGINE's `Egui::FontCuts` — the same
#               module the CSS font-weight cascade and the
#               inspector's smart selector resolve through.
#   Rendering — the visual test bed of the Crystal text stack: full
#               Latin + Cyrillic alphabets, digits, punctuation at a
#               range of sizes. Backend A/B (FreeType C with real
#               hinting vs the Crystal port of it — no libfreetype;
#               see src/egui/driver/{freetype,crystalfonts,text}.cr)
#               and a font-cut switcher (Regular / Bold / Italic /
#               Bold Italic, each from its own file through the
#               ACTIVE backend). Look for: solid crossbars (e, A, Б),
#               consistent baselines, even spacing, stem weight
#               parity between the cut tabs.
#
#   crystal run examples/font_lab.cr
#   rake build:dev[font_lab] && bin/apps/font_lab

require "../src/egui/driver_selector"
require "../src/egui/driver/crystalfonts"
# The C-FFI tab is part of the A/B toolset — font_lab links
# libfreetype unconditionally, even in release builds (it is the
# diagnostic app; shipped apps don't).
require "../src/egui/driver/freetype"

# One lab tab. #enter runs on every activation (theme + font setup);
# #render runs every frame with the panel's remaining Ui.
abstract class FontLabSection
  abstract def label : String
  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
  end

  abstract def render(ctx : Egui::Context, ui : Egui::Ui) : Nil
end

# ── Specimen ────────────────────────────────────────────────────────────

class FontBrowserSection < FontLabSection
  # Dropdown presets alongside the free slider (both write @size).
  SIZES = [12.0, 16.0, 20.0, 24.0, 32.0, 48.0, 64.0, 96.0]

  def label : String
    "Specimen"
  end

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

  # The STARTUP font chain (what Sokol's on_init installs: the system
  # font through the standard backend chain). The other tabs swap the
  # process font slots (Rendering re-selects its A/B backends every
  # frame, Markdown-vs-fonts installs the variant faces) — this tab
  # must not inherit them, so #enter re-selects the default.
  @default : Egui::Driver::AtlasFonts? = nil

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    apply_theme(ctx)
    if (stack = (@default ||= Egui::Driver::Sokol.fonts_from_system(
                    Egui::SystemPorts::Fonts.search_paths)))
      Egui::Driver::Sokol.select_fonts(stack)
    end
  end

  # Theme swap on change only — re-assigning every frame would
  # rebuild the preset and drop any runtime style state.
  private def apply_theme(ctx : Egui::Context) : Nil
    unless @applied_theme == @dark
      ctx.theme = @dark ? Egui::Theme.dark : Egui::Theme.light
      @applied_theme = @dark
    end
  end

  def render(ctx : Egui::Context, ui : Egui::Ui) : Nil
    apply_theme(ctx) # apply the dark/light toggle live

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

# ── Rendering ───────────────────────────────────────────────────────────

class FontPreviewSection < FontLabSection
  GROUPS = {
    "Latin upper"    => "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "Latin lower"    => "abcdefghijklmnopqrstuvwxyz",
    "Cyrillic upper" => "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ",
    "Cyrillic lower" => "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
    "Digits"         => "0123456789",
    "Punctuation"    => ".,:;!?—–-()[]{}«»\"'…",
  }

  SIZES = [12.0, 14.0, 16.0, 20.0, 24.0, 32.0]

  # Font cuts the whole preview can be drawn in (a second switcher row
  # under the backend tabs): cut key → label. Each cut loads from its
  # own file next to the regular face, through the active backend.
  CUTS = {
    "regular"     => "Regular",
    "bold"        => "Bold",
    "italic"      => "Italic",
    "bold_italic" => "Bold Italic",
  }

  # Filename style token → cut (dash convention "Family-Bold.ttf" and
  # the short codes of the dash-less one "Ubuntu-R.ttf" / "segoeuib.ttf";
  # a trailing variable-font "[wdth,wght]" axis list is stripped).
  STYLE_TOKENS = {
    "" => "regular", "regular" => "regular", "book" => "regular",
    "r" => "regular", "roman" => "regular",
    "bold" => "bold", "b" => "bold", "bd" => "bold",
    "italic" => "italic", "it" => "italic", "i" => "italic",
    "oblique" => "italic", "ri" => "italic",
    "bolditalic" => "bold_italic", "boldoblique" => "bold_italic",
    "bi" => "bold_italic", "z" => "bold_italic",
  }

  def label : String
    "Rendering"
  end

  @tab = 0
  @cut = 0
  @freetype : Egui::Driver::AtlasFonts?
  @crystal : Egui::Driver::AtlasFonts?

  # Style-cut stacks of the active tab, registered as named stacks
  # ("preview-<cut>") the whole preview can be routed through. Rebuilt
  # on a tab switch — the old tab's stacks (and their atlases) are
  # dropped with them.
  @style_stacks = {} of String => Egui::Driver::AtlasFonts
  @style_paths = {} of String => String
  @styles_tab = -1

  # Automation hook (kept under the historical name): the sapp C loop
  # pumps frames but never yields to the Crystal scheduler, so Signal
  # traps can't run — poll a control file instead
  # (echo 0|1 > /tmp/fontpreview.tab).
  CONTROL = "/tmp/fontpreview.tab"

  def enter(ctx : Egui::Context, base : Egui::Theme) : Nil
    ctx.theme = base
  end

  def render(ctx : Egui::Context, ui : Egui::Ui) : Nil
    # Both backends loaded once, then toggled live via Sokol.select_fonts:
    # each has its own atlas; the pipeline rebinds on the next frame.
    @freetype ||= Egui::Driver::FreetypeFonts.from_system(
      Egui::SystemPorts::Fonts.search_paths)
    @crystal ||= Egui::Driver::CrystalFonts.from_system(
      Egui::SystemPorts::Fonts.search_paths)

    # Automation hook: the file is CONSUMED on apply: a leftover value
    # must not pin the tab against every later click.
    if File.exists?(CONTROL)
      v = File.read(CONTROL).strip
      if {"0", "1"}.includes?(v)
        @tab = v.to_i
        File.delete(CONTROL)
      end
    end

    font = @tab.zero? ? @freetype : @crystal
    if font && font.loaded?
      Egui::Driver::Sokol.select_fonts(font)
    end
    rebuild_style_stacks_if_needed

    ui.horizontal do |row|
      row.selectable(@tab == 0, "FreeType (C)") { |v| @tab = 0 if v }
      row.selectable(@tab == 1, "Crystal port") { |v| @tab = 1 if v }
    end
    cut_key = CUTS.keys[@cut]
    ui.horizontal do |row|
      CUTS.each_with_index do |(key, label), i|
        if @cut == 0 || i == 0 || @style_stacks.has_key?(key)
          row.selectable(@cut == i, label) { |v| @cut = i if v }
        else
          # The family ships no such file — show the cut as missing
          # instead of silently drawing Regular.
          row.rich(Egui::RichText.new("#{label} (n/a)")
            .small(ui.style.font_size).weak(ui.style.visuals))
        end
      end
    end
    backend = @tab.zero? ? "FreeType" : "Crystal FreeType port"
    ui.heading("Font preview — #{backend} · #{CUTS.values[@cut]}")

    # Route the whole preview through the selected cut: widgets
    # measure and paint via ctx.fonts_for("preview-<cut>") — the
    # same pipeline a themed font_family rule rides. Regular is the
    # primary stack itself (family nil).
    ctx.style.font_family = @cut == 0 ? nil : "preview-#{cut_key}"

    GROUPS.each do |name, alphabet|
      ui.rich(Egui::RichText.new(name).small(ui.style.font_size).weak(ui.style.visuals))
      ui.label(alphabet)
    end

    ui.separator
    ui.rich(Egui::RichText.new("sizes").small(ui.style.font_size).weak(ui.style.visuals))
    SIZES.each do |size|
      ui.rich(Egui::RichText
        .new("AaEeОоБбЕе 0123 — hxeao: #{size.to_i}")
        .size(size))
    end

    ctx.style.font_family = nil
  end

  # ------------------------------------------------------------------
  # Style-cut discovery/loading

  # Discover the family's cut files next to the regular face and load
  # each through the ACTIVE tab's backend class, registering them as
  # named stacks ("preview-<cut>") the preview can be routed through.
  # "regular" needs no stack of its own (family nil = the primary).
  # Runs once per tab switch.
  private def rebuild_style_stacks_if_needed : Nil
    return if @styles_tab == @tab
    @styles_tab = @tab
    @style_stacks.clear
    @style_paths = discover_cut_paths
    @style_paths.each do |key, path|
      next if key == "regular"
      stack = @tab.zero? ? Egui::Driver::FreetypeFonts.from_system([path])
                         : Egui::Driver::CrystalFonts.from_system([path])
      next unless stack && stack.loaded?
      @style_stacks[key] = stack
      Egui::Driver::Sokol.register_font("preview-#{key}", stack)
    end
    @cut = 0 unless @cut == 0 || @style_stacks.has_key?(CUTS.keys[@cut])
  end

  # cut key → file path for the family of the FIRST loadable system
  # path. Siblings are matched by filename convention: the family
  # prefix plus a known style token, dash-separated
  # ("DejaVuSans-Bold.ttf", "LiberationSans-BoldItalic.ttf") or glued
  # ("Ubuntu-B.ttf", "segoeuib.ttf"). Unknown tokens (Condensed,
  # ExtraLight, Mono…) don't match, so sibling families stay out.
  private def discover_cut_paths : Hash(String, String)
    found = {} of String => String
    regular = Egui::SystemPorts::Fonts.search_paths.find { |p| File.exists?(p) }
    return found unless regular
    base = File.basename(regular, ".ttf").downcase
    prefix = base.includes?('-') ? base.rpartition('-').first : base
    Dir.glob(File.join(File.dirname(regular), "*"))
      .select { |p| p.downcase.ends_with?(".ttf") }
      .each do |p|
        b = File.basename(p, ".ttf").downcase
        token = if b == prefix
                  ""
                elsif b.starts_with?("#{prefix}-")
                  b[(prefix.size + 1)..]
                elsif b.size > prefix.size && b.starts_with?(prefix)
                  b[prefix.size..]
                else
                  next
                end
        token = token.split('[').first
        key = STYLE_TOKENS[token]?
        next unless key
        # Prefer the canonical long token ("bold" over "b"): glob order
        # is arbitrary, and a family shipping both must pick the pure
        # cut, not a compressed-code alias.
        better = !(old = found[key]?) ||
                 token_priority(token) < token_priority(style_token_of(old))
        found[key] = p if better
      end
    found
  end

  # 0 for the canonical long tokens, 1 for short codes — lower wins.
  private def token_priority(token : String) : Int32
    token.size <= 2 ? 1 : 0
  end

  private def style_token_of(path : String) : String
    b = File.basename(path, ".ttf").downcase
    b.includes?('-') ? b.rpartition('-').last : ""
  end
end

# ── the lab shell ───────────────────────────────────────────────────────

class FontLabApp < Egui::App
  @sections = [
    FontBrowserSection.new,
    FontPreviewSection.new,
  ] of FontLabSection
  @tab = 0
  @entered = -1
  @base : Egui::Theme? = nil

  def update(ctx : Egui::Context) : Nil
    @base ||= ctx.theme
    ctx.central_panel do |ui|
      ui.horizontal do |row|
        @sections.each_with_index do |section, i|
          row.selectable(@tab == i, section.label) { |v| @tab = i if v }
        end
      end
      ui.separator

      # Activation step: theme + per-section font setup, on tab change
      # only (re-assigning a theme every frame would rebuild presets).
      if @entered != @tab
        @entered = @tab
        @sections[@tab].enter(ctx, @base.not_nil!)
      end
      @sections[@tab].render(ctx, ui)
    end
  end
end

Egui.run(FontLabApp.new, title: "egui-cr — font lab",
  width: 1024, height: 800, inspector: :hidden)
