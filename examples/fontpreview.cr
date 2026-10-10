# Font rendering preview: the full Latin and Cyrillic alphabets, digits and
# punctuation at a range of sizes — the visual test bed for the Crystal
# text stack. Two switcher rows: the backend (FreeType C library with
# real hinting vs the Crystal port of it — backend/crystalfonts.cr, no
# libfreetype; see src/egui/backend/{freetype,crystalfonts,text}.cr) and
# the font cut (Regular / Bold / Italic / Bold Italic of the active
# family, each loaded from its own file through the ACTIVE backend).
# Look for: solid crossbars (e, A, Б), consistent baselines, even
# spacing, stem weight parity between the tabs.

require "../src/egui/backend_selector"
require "../src/egui/backend/crystalfonts"
# The C-FFI tab is part of the A/B toolset — fontpreview links
# libfreetype unconditionally, even in release builds (it is the
# diagnostic app; shipped apps don't).
require "../src/egui/backend/freetype"

class FontPreviewApp < Egui::App
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

  @tab = 0
  @cut = 0
  @freetype : Egui::Backend::AtlasFonts?
  @crystal : Egui::Backend::AtlasFonts?

  # Style-cut stacks of the active tab, registered as named stacks
  # ("preview-<cut>") the whole window can be routed through. Rebuilt
  # on a tab switch — the old tab's stacks (and their atlases) are
  # dropped with them.
  @style_stacks = {} of String => Egui::Backend::AtlasFonts
  @style_paths = {} of String => String
  @styles_tab = -1

  CONTROL = "/tmp/fontpreview.tab"

  def initialize
    super()
  end

  def update(ctx : Egui::Context) : Nil
    # Both backends loaded once, then toggled live via Sokol.select_fonts:
    # each has its own atlas; the pipeline rebinds on the next frame.
    @freetype ||= Egui::Backend::FreetypeFonts.from_system(
      Egui::SystemPorts::Fonts.search_paths)
    @crystal ||= Egui::Backend::CrystalFonts.from_system(
      Egui::SystemPorts::Fonts.search_paths)

    # Automation hook: the sapp C loop pumps frames but never yields
    # to the Crystal scheduler, so Signal traps can't run — poll a
    # control file instead (echo 0|1 > /tmp/fontpreview.tab). The
    # file is CONSUMED on apply: a leftover value must not pin the
    # tab against every later click.
    if File.exists?(CONTROL)
      v = File.read(CONTROL).strip
      if {"0", "1"}.includes?(v)
        @tab = v.to_i
        File.delete(CONTROL)
      end
    end

    font = @tab.zero? ? @freetype : @crystal
    if font && font.loaded?
      Egui::Backend::Sokol.select_fonts(font)
    end
    rebuild_style_stacks_if_needed

    ctx.window("fontpreview", Egui::Pos2.new(24.0, 24.0), width: 780.0) do |ui|
      ui.horizontal do |row|
        row.selectable(@tab == 0, "FreeType (C)") { |v| @tab = 0 if v }
        row.selectable(@tab == 1, "Crystal port") { |v| @tab = 1 if v }
      end
      cut_key = CUTS.keys[@cut]
      cut_available = @cut == 0 || @style_stacks.has_key?(cut_key)
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
      stack = @tab.zero? ? Egui::Backend::FreetypeFonts.from_system([path])
                         : Egui::Backend::CrystalFonts.from_system([path])
      next unless stack && stack.loaded?
      @style_stacks[key] = stack
      Egui::Backend::Sokol.register_font("preview-#{key}", stack)
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

Egui.run(FontPreviewApp.new, title: "egui-cr — fontpreview",
  width: 820, height: 760, inspector: :hidden)
