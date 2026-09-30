# Framework CLI options for apps launched through Backend.run: today
# one deep-link flag,
#
#   --page root/settings#theme
#
# which navigates the router straight to a page (and optionally focuses
# a widget) — how screenshots capture apps in specific states and how
# you jump into a debug state without clicking there. Everything else
# (file arguments, app-specific flags like notepad's `--theme`) passes
# through untouched, so apps keep their own ARGV parsing.
#
# The scan is hand-rolled on purpose: OptionParser delivers an unknown
# flag to BOTH the invalid_option callback and the leftover args, which
# duplicates it in the pass-through list.

module Egui
  module CLI
    # Extract the framework flags from `argv` (usually ARGV):
    # {route: "--page" value or nil, argv: the remaining arguments}.
    # Parses in place — ARGV is left holding only the app's own args
    # (notepad's file list still works). The LAST --page wins; a bare
    # `--page` with no value is dropped (route stays nil).
    def self.parse(argv : Array(String)) : NamedTuple(route: String?,
      argv: Array(String))
      route : String? = nil
      rest = [] of String
      only_args = false
      i = 0
      while i < argv.size
        arg = argv[i]
        if only_args
          rest << arg
        elsif arg == "--"
          only_args = true
        elsif arg == "--page" && (value = argv[i + 1]?)
          route = value
          i += 1
        elsif arg.starts_with?("--page=")
          route = arg.split('=', 2)[1]
        else
          rest << arg
        end
        i += 1
      end
      argv.clear
      rest.each { |a| argv << a }
      {route: route, argv: rest}
    end
  end
end
