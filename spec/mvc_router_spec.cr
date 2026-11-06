# MVC-роутер (backend-слой приложения, plans/frontend-backend-split.md
# §6): матчинг маршрутов, params, namespace, resources, контроллеры с
# actions-макросом, middleware, никогда не райзящий handle, конверт
# Request/Response. Тест-режим №1 из §9 — бэкенд в лоб, ни фронтенда,
# ни драйвера.

require "spec"
require "../src/egui"

describe Egui::Mvc::Router do
  it "matches verb routes and decodes :params" do
    router = Egui::Mvc::Router.new.draw do |r|
      r.get "/posts/:id" { |req| {"id" => req.params["id"]} }
    end
    resp = router.handle(Egui::Mvc::Request.new("GET", "/posts/42"))
    resp.status.should eq 200
    resp.body["id"].as_s.should eq "42"
  end

  it "URL-decodes param values" do
    router = Egui::Mvc::Router.new
    router.get "/files/:name" { |req| req.params["name"] }
    resp = router.handle(Egui::Mvc::Request.new("GET", "/files/a%20b"))
    resp.body.as_s.should eq "a b"
  end

  it "404s unmatched routes with the path in the error" do
    router = Egui::Mvc::Router.new
    router.get "/posts" { "hi" }
    resp = router.handle(Egui::Mvc::Request.new("GET", "/nope"))
    resp.status.should eq 404
    resp.ok?.should be_false
    resp.body["error"].as_s.should contain "no route: /nope"
  end

  it "separates methods (GET route does not answer POST)" do
    router = Egui::Mvc::Router.new
    router.get "/posts" { "list" }
    router.handle(Egui::Mvc::Request.new("POST", "/posts"))
      .status.should eq 404
  end

  it "rejects segments mismatch by count" do
    router = Egui::Mvc::Router.new
    router.get "/a/:x" { "ok" }
    router.handle(Egui::Mvc::Request.new("GET", "/a/b/c"))
      .status.should eq 404
  end

  it "nests with namespace" do
    router = Egui::Mvc::Router.new.draw do |r|
      r.namespace "/api" do |api|
        api.get "/projects" { "projects" }
      end
      r.get "/elsewhere" { "other" }
    end
    router.handle(Egui::Mvc::Request.new("GET", "/api/projects"))
      .body.as_s.should eq "projects"
    router.handle(Egui::Mvc::Request.new("GET", "/elsewhere"))
      .body.as_s.should eq "other"
  end

  it "parses inline and explicit query strings" do
    req = Egui::Mvc::Request.new("GET", "/x?a=1&b=two%20words")
    req.query["a"].should eq "1"
    req.query["b"].should eq "two words"
    explicit = Egui::Mvc::Request.new("GET", "/x",
      query: {"k" => "v"}, body: Egui::Mvc::EMPTY_BODY)
    explicit.query["k"].should eq "v"
  end

  it "uppercases the method once in the constructor" do
    Egui::Mvc::Request.new("post", "/x").method.should eq "POST"
  end

  describe "heavy" do
    it "flags individually marked blocks" do
      router = Egui::Mvc::Router.new
      route = router.get "/search", heavy: true do
        "s"
      end
      route.heavy.should be_true
      router.get "/light" { "l" }.heavy.should be_false
    end

    it "flags whole groups" do
      router = Egui::Mvc::Router.new.draw do |r|
        r.heavy do |h|
          h.get "/a" { "a" }
        end
        r.get "/b" { "b" }
      end
      router.routes.find { |rt| rt.path == "/a" }.not_nil!.heavy.should be_true
      router.routes.find { |rt| rt.path == "/b" }.not_nil!.heavy.should be_false
    end
  end

  it "runs middleware that may short-circuit" do
    router = Egui::Mvc::Router.new
    router.get "/posts" { "list" }
    Egui::Mvc::Router.use do |req|
      next Egui::Mvc::Response.new(401, Egui::Mvc::EMPTY_BODY) unless req.query["token"]? == "secret"
      nil
    end
    begin
      router.handle(Egui::Mvc::Request.new("GET", "/posts?token=wrong"))
        .status.should eq 401
      router.handle(Egui::Mvc::Request.new("GET", "/posts?token=secret"))
        .status.should eq 200
    ensure
      Egui::Mvc::Router.middleware.clear
    end
  end
end

# --- Controller + resources ---------------------------------------------

class MvcSpec::PostsController < Egui::Mvc::Controller
  # NOTE: the router serves actions through `.allocate` (no initialize
  # call — positron parity), so action state must come from the store,
  # not ivars. A local constant stands in for it here.
  POSTS = [{"id" => 1_i64, "title" => "a"}, {"id" => 2_i64, "title" => "b"}]

  def index(request)
    POSTS
  end

  def show(request)
    POSTS.find { |p| p["id"] == request.params["id"].to_i64 } ||
      Egui::Mvc::Response.new(404, Egui::Mvc::EMPTY_BODY)
  end

  def create(request)
    Egui::Mvc::Response.new(201,
      JSON::Any.new({"id" => JSON::Any.new(3_i64),
                     "title" => request.body["title"]}))
  end

  def update(request)
    {"updated" => request.params["id"]}
  end

  def destroy(request)
    Egui::Mvc::Response.new(204, Egui::Mvc::EMPTY_BODY)
  end

  actions
end

describe "Mvc resources" do
  it "draws the CRUD route set into a controller" do
    router = Egui::Mvc::Router.new
    router.resources "/posts", MvcSpec::PostsController

    router.handle(Egui::Mvc::Request.new("GET", "/posts"))
      .body.as_a.size.should eq 2
    router.handle(Egui::Mvc::Request.new("GET", "/posts/1"))
      .body["title"].as_s.should eq "a"
    router.handle(Egui::Mvc::Request.new("GET", "/posts/99"))
      .status.should eq 404
    created = router.handle(Egui::Mvc::Request.new("POST", "/posts",
      body: JSON::Any.new({"title" => JSON::Any.new("c")})))
    created.status.should eq 201
    created.body["title"].as_s.should eq "c"
    router.handle(Egui::Mvc::Request.new("PATCH", "/posts/7"))
      .body["updated"].as_s.should eq "7"
    router.handle(Egui::Mvc::Request.new("DELETE", "/posts/1"))
      .status.should eq 204
  end
end

class MvcSpec::HeavyController < Egui::Mvc::Controller
  @[Egui::Mvc::Heavy]
  def index(request)
    "heavy index"
  end

  def show(request)
    "light show"
  end

  actions
end

describe "Mvc Controller" do
  it "propagates @[Heavy] annotations through heavy_action?" do
    MvcSpec::HeavyController.heavy_action?("index").should be_true
    MvcSpec::HeavyController.heavy_action?("show").should be_false
  end

  it "marks controller-heavy routes without a block flag" do
    router = Egui::Mvc::Router.new
    router.get "/h", MvcSpec::HeavyController, "index"
    router.get "/l", MvcSpec::HeavyController, "show"
    router.routes[0].heavy.should be_true
    router.routes[1].heavy.should be_false
  end

  it "wraps handler exceptions into 500 with the root cause" do
    router = Egui::Mvc::Router.new
    router.get "/boom" { |req| raise ArgumentError.new("kaboom") }
    resp = router.handle(Egui::Mvc::Request.new("GET", "/boom"))
    resp.status.should eq 500
    resp.body["error"].as_s.should eq "kaboom"
  end

  it "raises on unknown action names (programming error)" do
    # Reachable only by calling the dispatch table directly — routes
    # always register existing action names. Kept as a guard on the
    # `actions` macro's else branch.
    instance = MvcSpec::PostsController.allocate.as(Egui::Mvc::Controller)
    instance.set_request(Egui::Mvc::Request.new("GET", "/x"))
    expect_raises(Exception, /unknown action/) do
      instance.action_response("nope")
    end
  end
end
