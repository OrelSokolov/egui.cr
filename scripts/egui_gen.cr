# egui-gen — the exml build step (plans/NativeHTML.md §6, Route A).
#
# Pre-parses an .exml file and emits the literal `Array(Node)` tree as
# Crystal source — the same Nodes the runtime parser would build, so
# the renderer stays ONE and the XML parse disappears from the first
# frame (and from release binaries that only require the generated
# module). The generated file is data, never hand-edited:
#
#   crystal run scripts/egui_gen.cr -- assets/notepad.exml src/gen/notepad_gen.cr
#   crystal run scripts/egui_gen.cr -- ui.exml                  # → ui_gen.cr
#   crystal run scripts/egui_gen.cr -- ui.exml out.cr --module NotepadUi
#
# The app side picks the source with `Document.hybrid`:
#
#   require "egui"
#   require "./gen/notepad_gen"   # defines NotepadUi.document
#   doc = Egui::Exml::Document.hybrid(path) { NotepadUi.document }

require "../src/egui"

input = ARGV.reject(&.starts_with?('-'))
if input.empty? || ARGV.includes?("--help") || ARGV.includes?("-h")
  STDERR.puts "usage: crystal run scripts/egui_gen.cr -- <file.exml> [<out.cr>] [--module <Name>]"
  exit(input.empty? ? 1 : 0)
end

src = input[0]
unless File.file?(src)
  STDERR.puts "egui-gen: no such file: #{src}"
  exit 1
end

out_path = input[1]? || src.gsub(/\.exml$/, "") + "_gen.cr"
if (mi = ARGV.index("--module")) && (mn = ARGV[mi + 1]?)
  module_name = mn
else
  module_name = "EguiGen"
end

doc = Egui::Exml::Document.load(src)
if doc.pages.empty?
  STDERR.puts "egui-gen: #{src} parsed to no pages — nothing generated"
  exit 1
end

File.write(out_path, Egui::Exml.emit_crystal(doc, source: src,
  module_name: module_name))
puts "egui-gen: #{src} → #{out_path} (#{doc.pages.size} pages, " \
     "#{doc.partials.size} partials, module #{module_name})"
