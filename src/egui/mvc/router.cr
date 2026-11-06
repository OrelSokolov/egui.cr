# Backend-слой приложения (plans/frontend-backend-split.md §6): Router →
# Controller → действие/ресурс. Порт positron'овского `http_router.cr`
# (байт-в-байт по семантике: конверт Request/Response, middleware,
# namespace, resources, флаг heavy) в egui.cr как общий код до выноса
# в монорепу tentacles. Пока без привязки к UI — головной тест-режим:
#
#   resp = App.router.handle(Request.new("GET", "/posts"))
#   resp.status.should eq 200
#
# Пространство имён `Mvc` отличает слой от фронтенда: `Egui::Router` —
# это роутер СТРАНИЦ ОКНА (egui/router.cr), а этот — роутер КОМАНД
# бэкенда. Разные роутеры с разными ролями, оба остаются, каждый в
# своём слое.
#
# Work-семантика (как в positron):
#   light (default) — обработчик бежит в файбере вызвавшего
#   heavy           — CPU/блокирующая работа; в in-process исполнении
#                     (однопоточный планировщик Crystal) пока бежит там
#                     же — флаг сохранён для пулов/джобов (§6.1)

module Egui
  module Mvc
    # Пустое JSON-тело (`{}`) — дефолт конверта.
    EMPTY_BODY = JSON::Any.new({} of String => JSON::Any)

    # Virtual HTTP layer: the frontend issues `Egui.request "GET", "/api/…"`,
    # the router matches it against routes drawn with `Router#draw`, and
    # the handler result resolves the callback. 4xx/5xx resolve (fetch
    # semantics); `#handle` never raises.
    class Router
      class Route
        getter method : String
        getter path : String
        getter segments : Array(String)
        getter handler : Handler
        getter heavy : Bool

        def initialize(@method : String, path : String, @handler : Handler, heavy : Bool = false)
          @path = path
          @segments = Router.split(path)
          @heavy = heavy
        end
      end

      # A route target: either a block or a controller#action pair.
      abstract class Handler
        abstract def call(request : Request) : Response
      end

      # Generic over the block's return type: action blocks return any
      # JSON-able value (or Response); `Response.wrap` runs at dispatch
      # time. The direct `&block` pass-through is deliberate — wrapping
      # the captured block into ANOTHER block literal trips a Crystal
      # 1.21 codegen bug when the block's body never returns (a
      # raise-only handler): "Cast from Nil to ProcInstanceType".
      class BlockHandler(T) < Handler
        def initialize(&@block : Request -> T)
        end

        def call(request : Request) : Response
          Response.wrap(@block.call(request))
        end
      end

      class ControllerHandler < Handler
        def initialize(@controller_class : Controller.class, @action : String)
        end

        def call(request : Request) : Response
          instance = @controller_class.allocate.as(Controller)
          instance.set_request(request)
          Response.wrap(instance.action_response(@action))
        end
      end

      # Full pipeline: middleware, match, execute. Never raises — a
      # handler exception becomes a 500 Response.
      def handle(request : Request) : Response
        Router.middleware.each do |mw|
          early = mw.call(request)
          return early if early
        end
        found = match(request.method, request.path)
        return Response.not_found(request.path) unless found
        route, params = found
        request.params = params
        route.handler.call(request)
      rescue ex : Exception
        Response.internal_error(ex)
      end

      @@middleware = [] of Request -> Response | Nil

      def self.middleware : Array(Request -> Response | Nil)
        @@middleware
      end

      # Register a middleware proc: return a Response to short-circuit the
      # request, or nil to pass to the next layer (middleware, then route).
      def self.use(&middleware : Request -> Response | Nil) : Nil
        @@middleware << middleware
      end

      getter routes : Array(Route)

      def initialize
        @routes = [] of Route
        @heavy_group = false
        @prefix = ""
      end

      def self.split(path : String) : Array(String)
        path.split('/').reject(&.empty?)
      end

      def draw(&) : self
        yield self
        self
      end

      # Nest routes under a path prefix:
      #   namespace "/api" do
      #     get "/projects" { ... }   # matches GET /api/projects
      #   end
      def namespace(prefix : String, & : self ->) : self
        outer = @prefix
        @prefix = "#{outer}#{prefix.chomp("/")}"
        begin
          yield self
        ensure
          @prefix = outer
        end
        self
      end

      # Group routes whose handlers do CPU/blocking work. Blocks may also be
      # marked individually with `heavy: true` on each verb method.
      def heavy(& : self ->) : self
        @heavy_group = true
        begin
          yield self
        ensure
          @heavy_group = false
        end
        self
      end

      {% for verb in %w(get post put patch delete) %}
        def {{verb.id}}(path : String, heavy : Bool = false, &block : Request -> _) : Route
          add_route({{verb}}, path, BlockHandler.new(&block), heavy: heavy || @heavy_group)
        end

        def {{verb.id}}(path : String, controller : Controller.class, action : String, heavy : Bool = false) : Route
          heavy = heavy || @heavy_group || controller.heavy_action?(action)
          add_route({{verb}}, path, ControllerHandler.new(controller, action), heavy: heavy)
        end
      {% end %}

      # Rails-style resource routes for a controller: index, show, create,
      # update, destroy (new/edit are the frontend's job).
      def resources(path : String, controller : Controller.class, heavy : Bool = false) : Nil
        base = path.chomp("/")
        get "#{base}", controller, "index", heavy: heavy
        post "#{base}", controller, "create", heavy: heavy
        get "#{base}/:id", controller, "show", heavy: heavy
        put "#{base}/:id", controller, "update", heavy: heavy
        patch "#{base}/:id", controller, "update", heavy: heavy
        delete "#{base}/:id", controller, "destroy", heavy: heavy
      end

      def add_route(method : String, path : String, handler : Handler, heavy : Bool = false) : Route
        route = Route.new(method.downcase, "#{@prefix}#{path}", handler, heavy: heavy)
        @routes << route
        route
      end

      def match(method : String, path : String) : Tuple(Route, Hash(String, String))?
        wanted = Router.split(path)
        @routes.each do |route|
          next unless route.method == method.downcase
          params = Router.match_segments(route.segments, wanted)
          return {route, params} if params
        end
        nil
      end

      def self.match_segments(pattern : Array(String), wanted : Array(String)) : Hash(String, String)?
        return nil unless pattern.size == wanted.size
        params = Hash(String, String).new
        pattern.each_with_index do |seg, i|
          if seg.starts_with?(':')
            params[seg[1..]] = URI.decode_www_form(wanted[i])
          elsif seg != wanted[i]
            return nil
          end
        end
        params
      end
    end

    struct Request
      getter method : String
      getter path : String
      getter query : Hash(String, String)
      getter body : JSON::Any
      property params : Hash(String, String)

      def initialize(method : String, path : String, query : Hash(String, String) = Hash(String, String).new, body : JSON::Any = JSON::Any.new({} of String => JSON::Any))
        @method = method.upcase
        path, _, inline_query = path.partition('?')
        @path = path
        @query = query.empty? ? Request.parse_query(inline_query) : query
        @body = body
        @params = Hash(String, String).new
      end

      def self.parse_query(raw : String?) : Hash(String, String)
        return Hash(String, String).new unless raw && !raw.empty?
        Hash(String, String).new.tap do |h|
          raw.split('&').each do |pair|
            key, _, value = pair.partition('=')
            next if key.empty?
            h[URI.decode_www_form(key)] = URI.decode_www_form(value)
          end
        end
      end
    end

    struct Response
      property status : Int32
      property body : JSON::Any

      def initialize(@status : Int32, @body : JSON::Any)
      end

      def ok? : Bool
        status < 400
      end

      def self.wrap(value : Response) : Response
        value
      end

      def self.wrap(value : JSON::Any) : Response
        new(200, value)
      end

      def self.wrap(value : _) : Response
        new(200, JSON::Any.new(JSON::PullParser.new(value.to_json)))
      end

      def self.not_found(path : String) : Response
        new(404, JSON::Any.new({"error" => JSON::Any.new("no route: #{path}")}))
      end

      def self.internal_error(ex : Exception) : Response
        root = ex
        while (c = root.cause) && c != root
          root = c
        end
        new(500, JSON::Any.new({"error" => JSON::Any.new(root.message || root.class.name)}))
      end

      def to_json : String
        {"status" => @status, "body" => @body}.to_json
      end
    end

    # Inherit and define action methods taking `Request`. Mark CPU/blocking
    # actions with @[Heavy]. Call the `actions` macro at the end of the class
    # body to generate the dispatch table.
    #
    #     class TasksController < Egui::Mvc::Controller
    #       @[Heavy]
    #       def index(request); ...; end
    #
    #       def update(request); ...; end
    #       actions
    #     end
    abstract class Controller
      @request : Request?

      def set_request(request : Request) : Nil
        @request = request
      end

      # The request being served (set by the router before the action runs).
      protected def request : Request
        @request.not_nil!
      end

      def action_response(name : String)
        raise "#{self.class} must call the `actions` macro at the end of its body"
      end

      def self.heavy_action?(name : String) : Bool
        false
      end

      # Action methods return any JSON-able value (or a Response for custom
      # status codes). @[Heavy] actions run on the worker pool.
      macro actions
        \{% begin %}
          def action_response(name : String)
            case name
            \{% for method in @type.methods %}
              \{% if method.name != "initialize" && method.name != "set_request" %}
                when \{{method.name.stringify}}
                  \{{method.name.id}}(request)
              \{% end %}
            \{% end %}
            else
              raise "unknown action #{name} for \{{@type}}"
            end
          end

          def self.heavy_action?(name : String) : Bool
            \{% heavy = [] of StringLiteral %}
            \{% for method in @type.methods %}
              \{% if method.annotation(Egui::Mvc::Heavy) %}
                \{% heavy << method.name.stringify %}
              \{% end %}
            \{% end %}
            \{% if heavy.empty? %}
              false
            \{% else %}
              \{{heavy}}.includes?(name)
            \{% end %}
          end
        \{% end %}
      end
    end

    annotation Heavy; end
  end
end
