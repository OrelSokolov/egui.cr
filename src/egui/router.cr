# egui.cr-native router: page-based app architecture inside a window.
#
# An app is a set of PAGES addressed `window/page` (plus an optional
# `#fragment` naming a widget to focus). One window exists today, so
# the window part is always "root" (multi-window later); the default
# page — what hello world shows — is "root/root", notepad's settings
# are "root/settings":
#
#   bin/notepad --page root/settings       # open straight into settings
#   bin/notepad --page root/settings#theme # …and focus the theme field
#
# The route is framework state, not per-app flags: the same mechanism
# drives debugging, CLI deep links and (later) screenshot generation
# in arbitrary app states.
#
# Usage — declare the pages inside `update`, immediate-mode style; the
# router renders the route stack when the block ends:
#
#   def update(ctx)
#     ctx.routes do |r|
#       r.page "root/root" do |ui| …the home UI… end
#       r.page "root/settings", title: "Settings" do |ui| … end
#       r.modal "root/confirm-close", title: "Save changes?" do |ui| … end
#     end
#   end
#
# A `page` is a full-window opaque Egui::Page replacing everything
# below it in the stack; a `modal` is ALSO a page — an addressable
# overlay route rendered as the semi-transparent scrim + centered
# card (Context#modal look). Back buttons pop the stack; fragments
# land focus on widgets created with a matching `focus_id:`.
#
# Unknown addresses are a SOFT warning: one line on stderr plus a
# "Page not found" page with a back button — never a crash.

module Egui
  # One address in the `window/page#fragment` scheme.
  struct Route
    getter window : String
    getter page : String
    getter fragment : String?

    # The default address every routed app starts at.
    def self.root : Route
      new("root", "root")
    end

    def initialize(@window : String, @page : String,
                   @fragment : String? = nil)
    end

    # Parse `root/settings#widget` → window/page/fragment. A single
    # segment ("settings") means the root window. Nil for anything
    # unparsable — including windows other than "root" (one window
    # today; multi-window is a separate plan).
    def self.parse(address : String) : Route?
      hash_parts = address.split('#', 2)
      addr = hash_parts[0]?
      frag = hash_parts[1]?
      return nil if addr.nil? || addr.empty?
      case (parts = addr.split('/')).size
      when 1 then window, page = "root", parts[0]
      when 2 then window, page = parts[0], parts[1]
      else        return nil
      end
      return nil if window != "root" || page.empty?
      new(window, page, frag.presence)
    end

    def ==(other : Route) : Bool
      window == other.window && page == other.page &&
        fragment == other.fragment
    end

    def hash(hasher)
      hasher = window.hash(hasher)
      hasher = page.hash(hasher)
      fragment.hash(hasher)
    end

    # The page identity without the fragment — the registry key.
    def page_id : String
      "#{window}/#{page}"
    end

    def to_s : String
      fragment ? "#{page_id}##{fragment}" : page_id
    end

    def to_s(io : IO) : Nil
      io << to_s
    end
  end

  # The route stack + per-frame page registry, drawn by `ctx.routes`.
  class Router
    getter ctx : Context

    class PageDecl
      property title : String?
      property width : Float64
      getter block : Proc(Ui, Nil)
      getter? modal : Bool

      def initialize(@block : Proc(Ui, Nil), @title : String?,
                     @modal : Bool, @width : Float64)
      end
    end

    @stack : Array(Route)
    # The route whose #fragment still owes a focus (set by navigate,
    # cleared when a widget with a matching focus_id takes it).
    @pending : Route?
    # The fragment of the page being rendered RIGHT NOW (nil while no
    # page block runs) — scopes focus names to their own page.
    @active_fragment : String? = nil
    @decls : Hash(String, PageDecl) = {} of String => PageDecl
    @warned : Set(String) = Set(String).new

    def initialize(@ctx : Context)
      @stack = [Route.root]
      @pending = nil
    end

    # The address on top of the stack.
    def current : Route
      @stack.last
    end

    # Push an address ("root/settings#theme"). Navigating to a page
    # already in the stack goes BACK to it (the stack is truncated
    # there — no duplicate entries). The fragment (if any) is armed to
    # focus a `focus_id:`-named widget on the page. Unparsable
    # addresses are a soft warning, nothing changes.
    def navigate(address : String) : Nil
      unless (route = Route.parse(address))
        warn_once("page not found: #{address}")
        return
      end
      if (idx = @stack.index { |r| r.page_id == route.page_id })
        @stack = @stack[0..idx]
      else
        @stack << route
      end
      arm_fragment(route)
      @ctx.request_repaint
    end

    # Pop to the previous page (the Page back button).
    def back : Nil
      return unless @stack.size > 1
      @stack.pop
      @pending = nil
      @ctx.request_repaint
    end

    # Replace the top of the stack (no back entry left behind).
    def replace(address : String) : Nil
      @stack.pop if @stack.size > 1
      navigate(address)
    end

    protected def arm_fragment(route : Route) : Nil
      @pending = route.fragment ? route : nil
    end

    # Called by Ui#named_id while a page renders: does this page owe
    # focus to the widget named `name`? Consumes the pending fragment
    # on a match.
    protected def fragment_armed?(name : String) : Bool
      if @active_fragment == name
        @active_fragment = nil
        @pending = nil
        true
      else
        false
      end
    end

    # --- per-frame declaration + render (Context#routes) ---------------

    # A full-window opaque page (renders via Context#page; the back
    # button pops the stack when a page sits below).
    def page(address : String, title : String? = nil,
             &block : Ui ->) : Nil
      register(Route.parse(address), title, modal: false,
        width: 0.0, block: block)
    end

    # A modal page: an addressable overlay route — the semi-transparent
    # scrim + centered card (Context#modal), focusable/deep-linkable
    # like any page. "A modal is just a page."
    def modal(address : String, title : String? = nil,
              width : Float64 = 480.0, &block : Ui ->) : Nil
      register(Route.parse(address), title, modal: true,
        width: width, block: block)
    end

    private def register(route : Route?, title : String?, modal : Bool,
                         width : Float64, block : Proc(Ui, Nil)) : Nil
      return unless route
      @decls[route.page_id] =
        PageDecl.new(block, title, modal, width)
    end

    protected def begin_frame : Nil
      @decls.clear
    end

    protected def render : Nil
      return if @decls.empty? # app declared no pages this frame

      top = @stack.last
      if (decl = @decls[top.page_id]?)
        if decl.modal?
          render_stack_with_modal_base(top)
        else
          render_page(top, decl)
        end
      else
        render_not_found(top)
      end
    end

    # The top route is a modal: render the topmost full page below it,
    # then every modal route above that base, in stack order.
    private def render_stack_with_modal_base(top : Route) : Nil
      base_idx = @stack.rindex { |r|
        (d = @decls[r.page_id]?) && !d.modal?
      }
      if base_idx.nil?
        render_not_found(top)
        return
      end
      render_page(@stack[base_idx], @decls[@stack[base_idx].page_id].not_nil!)
      # Snapshot: a modal's buttons may pop the stack (router.back)
      # while this loop is still rendering the routes above the base.
      @stack[(base_idx + 1)..].dup.each do |route|
        if (d = @decls[route.page_id]?) && d.modal?
          render_modal(route, d)
        else
          # A non-modal or unregistered route above the base: nothing
          # sensible to draw for it — soft warn and skip.
          warn_once("page not found: #{route}")
        end
      end
    end

    private def render_page(route : Route, decl : PageDecl) : Nil
      on_back = @stack.size > 1 ? -> { self.back; nil } : nil
      @active_fragment = @pending == route ? route.fragment : nil
      @ctx.page(route.page, title: decl.title, on_back: on_back) do |ui|
        decl.block.call(ui)
      end
      @active_fragment = nil
    end

    private def render_modal(route : Route, decl : PageDecl) : Nil
      # The scrim is the modal page's "back": a click on the dimmed
      # area outside the card pops the route (no back button — the
      # card is a content dialog, not a page with a header).
      @ctx.modal(route.page, width: decl.width, title: decl.title,
        on_scrim_click: -> { self.back; nil }) do |ui|
        decl.block.call(ui)
      end
    end

    # The soft "page not found" page — the back button pops, or goes
    # home when there is nothing under the bad route.
    private def render_not_found(route : Route) : Nil
      warn_once("page not found: #{route}")
      on_back = @stack.size > 1 ? -> { self.back; nil } : nil
      @ctx.page("not_found", title: "Not found", on_back: on_back) do |ui|
        ui.label("Page not found: #{route}")
        if on_back.nil?
          if ui.button("Go to root/root").clicked?
            # Nothing under the bad route: reset the stack to home.
            @stack = [Route.root]
            @pending = nil
            @ctx.request_repaint
          end
        end
      end
    end

    private def warn_once(message : String) : Nil
      return if @warned.includes?(message)
      @warned << message
      STDERR.puts "egui: warning: #{message}"
    end
  end

  class Context
    @router : Router? = nil

    # The app's route stack (see `Egui::Router`). Lazy: apps that never
    # call #routes never allocate one.
    def router : Router
      @router ||= Router.new(self)
    end

    def router? : Router?
      @router
    end

    # Declare this frame's pages and render the current route stack
    # when the block ends (see `Egui::Router`):
    #
    #   ctx.routes do |r|
    #     r.page "root/root" { |ui| … }
    #     r.modal "root/confirm", title: "Sure?" { |ui| … }
    #   end
    def routes(& : Router ->) : Nil
      r = router
      r.begin_frame
      yield r
      r.render
    end
  end
end
