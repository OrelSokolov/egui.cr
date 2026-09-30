# System port Fonts: candidate system font files for the default UI
# font, best-first. Pure platform data — the list is selected at compile
# time (win32 / darwin / everything else reads as Linux/BSD), no native
# calls needed, so the port stays headless-testable.
#
# The backend (backend/sokol.cr#fonts_from_system) feeds these to the
# font backends (CrystalFonts → LightHintedFonts; + the C-FFI
# FreetypeFonts accelerator first in dev builds with C_EXTENSIONS);
# the first file that loads wins.
# Apps can pass their own bundled font before falling back to these.

module Egui
  module SystemPorts
    module Fonts
      # Candidate font files, best-first (plain .ttf — both backends
      # load a single face, not .ttc collections).
      def self.search_paths : Array(String)
        {% if flag?(:win32) %}
          [
            "C:\\Windows\\Fonts\\segoeui.ttf",  # Segoe UI — the system font
            "C:\\Windows\\Fonts\\arial.ttf",
            "C:\\Windows\\Fonts\\tahoma.ttf",
          ]
        {% elsif flag?(:darwin) %}
          [
            "/System/Library/Fonts/SFNS.ttf",                  # San Francisco
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/Library/Fonts/Arial.ttf",
          ]
        {% else %}
          [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
            "/usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
          ]
        {% end %}
      end

      # Font DIRECTORY roots #installed_families scans (recursively).
      def self.font_dirs : Array(String)
        home = ENV["HOME"]? || "."
        {% if flag?(:win32) %}
          ["C:\\Windows\\Fonts"]
        {% elsif flag?(:darwin) %}
          ["/System/Library/Fonts", "/Library/Fonts", "#{home}/Library/Fonts"]
        {% else %}
          ["/usr/share/fonts", "/usr/local/share/fonts",
           "#{home}/.local/share/fonts", "#{home}/.fonts"]
        {% end %}
      end

      # Every installed family NAME → its representative regular file
      # (a .ttf the backends can load — no .ttc collections, no CFF
      # 'OTTO' faces). The name comes from each file's SFNT `name`
      # table (nameID 1), read as a few seek'd byte RANGES — the font
      # itself is never parsed here; the stack materializes lazily on
      # first use (`Context#register_deferred_font`). Unreadable files
      # degrade silently: a family nobody picks must not cost a
      # warning.
      def self.installed_families : Hash(String, String)
        families = {} of String => String
        scores = {} of String => Int32
        font_dirs.each do |dir|
          next unless Dir.exists?(dir)
          Dir.glob("#{dir}/**/*") do |path|
            next unless path.downcase.ends_with?(".ttf")
            next unless File.file?(path)
            name = family_name(path)
            next unless name && !name.empty?
            score = representative_score(path)
            next if (old_score = scores[name]?) && old_score >= score
            families[name] = path
            scores[name] = score
          end
        end
        families
      end

      # Which file to show a family by: the plain cut (Regular/Book/R)
      # over styled ones (Bold/Italic/Light…). The style token is the
      # segment after the last '-' of the filename (the classic
      # "Family-Style.ttf" naming); unrecognized shapes score 0 and
      # ties keep the first seen.
      private def self.representative_score(path : String) : Int32
        base = File.basename(path, ".ttf").downcase
        style = base.split('-').last? || base
        case style
        when "regular", "book", "r"    then 4
        when "roman"                   then 3
        when "medium", "md"            then 1
        when "light", "lt", "l", "thin", "th", "hairline",
             "extralight", "ultralight" then -1
        when "bold", "b", "bd", "semibold", "sb", "extrabold",
             "black", "bl", "heavy", "it", "li", "bi" then -2
        else
          return -3 if style.ends_with?("italic") || style.includes?("oblique")
          return -1 if style.includes?("light")
          0
        end
      end

      # Family name (SFNT `name` table, nameID 1) read straight off
      # the file: 12-byte header → table records → the `name` table's
      # own header + records, then only the winning string's bytes.
      # A handful of small reads per file, no glyph data touched.
      private def self.family_name(path : String) : String?
        File.open(path) do |io|
          head = read_bytes(io, 12) || return nil
          version = be_u32(head, 0)
          # 0x00010000 = TrueType outlines ('true' is the legacy tag);
          # 'ttcf' collections and 'OTTO' CFF faces are not loadable.
          return nil unless version == 0x0001_0000 || version == 0x7472_7565
          num_tables = be_u16(head, 4)
          return nil if num_tables.zero? || num_tables > 256
          records = read_bytes(io, num_tables * 16) || return nil
          name_off = 0_u32
          num_tables.times do |i|
            off = i * 16
            if records[off, 4] == NAME_TAG
              name_off = be_u32(records, off + 8)
              break
            end
          end
          return nil if name_off.zero?
          io.seek(name_off)
          hdr = read_bytes(io, 6) || return nil
          count = be_u16(hdr, 2)
          str_off = be_u16(hdr, 4)
          return nil if count > 4096
          recs = read_bytes(io, count * 12) || return nil
          best = nil
          best_pref = 0
          count.times do |i|
            off = i * 12
            platform = be_u16(recs, off)
            next unless be_u16(recs, off + 6) == 1 # nameID 1: family
            pref = case platform
                   when 3 then 4       # Windows (UTF-16BE)
                   when 0 then 3       # Unicode (UTF-16BE)
                   when 1 then 2       # Macintosh (Roman)
                   else next
                   end
            pref += 1 if platform == 3 && be_u16(recs, off + 4) == 0x0409
            next unless pref > best_pref
            length = be_u16(recs, off + 8)
            next if length.zero? || length > 512
            io.seek(name_off + str_off + be_u16(recs, off + 10))
            bytes = read_bytes(io, length) || next
            best = decode_name(bytes, platform)
            best_pref = pref unless best.nil?
          end
          best
        end
      rescue IO::Error | File::Error | ArgumentError
        nil # a broken/corrupt file is skipped, not fatal
      end

      NAME_TAG = "name".to_slice # the SFNT table tag compared as bytes

      # name-table strings: UTF-16BE on the Unicode/Windows platforms,
      # Mac Roman read as Latin-1 (family names are ASCII in practice).
      private def self.decode_name(bytes : Bytes, platform : Int32) : String?
        s = if platform == 1
              String.build do |b|
                bytes.each { |v| b.write_byte(v) }
              end
            else
              String.build do |b|
                (bytes.size // 2).times do |i|
                  cp = bytes[i * 2].to_u16 << 8 | bytes[i * 2 + 1]
                  b << cp.unsafe_chr
                end
              end
            end
        cleaned = s.strip
        cleaned.empty? ? nil : cleaned
      end

      private def self.read_bytes(io : IO, n : Int32) : Bytes?
        buf = Bytes.new(n)
        io.read_fully(buf)
        buf
      rescue IO::Error
        nil
      end

      private def self.be_u16(buf : Bytes, off : Int32) : Int32
        buf[off].to_i32 << 8 | buf[off + 1]
      end

      private def self.be_u32(buf : Bytes, off : Int32) : UInt32
        buf[off].to_u32 << 24 | buf[off + 1].to_u32 << 16 |
          buf[off + 2].to_u32 << 8 | buf[off + 3].to_u32
      end
    end
  end
end
