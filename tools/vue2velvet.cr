#!/usr/bin/env crystal
# vue2velvet CLI (plans/vue2velvet.md) — the port tool's front end:
# a Vue SFC's template+style halves → .exml + .ecss beside the
# source (or under -o DIR). The script half is NEVER translated —
# the report says what the Crystal Component must publish.

require "option_parser"
require "../src/egui/vue2velvet"

out_dir = nil
usage = "usage: vue2velvet Component.vue [-o DIR]"
OptionParser.parse do |o|
  o.on("-o DIR", "--out DIR", "output directory (default: beside the source)") { |d| out_dir = d }
  o.missing_option do
    STDERR.puts usage
    exit 1
  end
end

path = ARGV[0]?
if path.nil? || !File.file?(path)
  STDERR.puts usage
  exit 1
end

base = File.basename(path, File.extname(path))
result = Egui::Vue2Velvet.convert(File.read(path), base)
dir = out_dir
dir = File.dirname(path) if dir.nil?
result.write(dir).each { |f| puts "wrote #{f}" }
puts
result.report.each { |line| puts line }
exit(result.ok? ? 0 : 1)
