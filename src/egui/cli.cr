# Framework CLI options for apps launched through Backend.run: today
# one deep-link flag,
#
#   --page root/settings#theme
#
# which navigates the router straight to a page (and optionally focuses
# a widget) — how screenshots capture apps in specific states and how
# you jump into a debug state without clicking there. Everything else
# (file arguments, app-specific flags) passes through untouched, so
# apps keep their own ARGV parsing.

require "option_parser"

module Egui
  module CLI
    # Extract the framework flags from `argv` (usually ARGV):
    # {route: "--page" value or nil, argv: the remaining arguments}.
    # Parses in place — ARGV is left holding only the app's own args
    # (notepad's file list still works). An unknown flag raises
    # OptionParser::InvalidOption as usual; the LAST --page wins.
    def self.parse(argv : Array(String)) : NamedTuple(route: String?,
      argv: Array(String))
      route : String? = nil
      rest = [] of String
      OptionParser.new do |p|
        p.on("--page ADDRESS",
          "Open the app at a page route (window/page#widget)") { |a| route = a }
        p.unknown_args { |args| rest = args }
      end.parse(argv)
      {route: route, argv: rest}
    end
  end
end
