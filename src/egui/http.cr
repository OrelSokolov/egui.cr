# HTTP client seam (no upstream counterpart — egui apps own their IO).
#
# The core's fetch pipeline: `Http.get(url) { |result| … }` runs the
# request in its own worker fiber and delivers the result BETWEEN
# frames — the AsyncDialogs contract (see system_ports/dialog.cr):
#
#   * the callback fires in the worker fiber the moment the fetch
#     finishes, never mid-frame (fibers only advance when the Crystal
#     scheduler yields — on_frame pumps it before begin_frame);
#   * completion bumps a delivered counter the backend consumes as a
#     produce-a-frame trigger (`take_delivered`) and knocks on the
#     backend doorbell via `Egui::Runtime.wake` (detached loop);
#   * `pump_pass` is the legacy single-thread crutch (one bounded
#     scheduler pass per frame, like `AsyncDialogs.pump_pass`).
#
# The default fetcher is the Crystal stdlib `HTTP::Client` (blocking
# IO — fiber-safe; 10 s connect/read timeouts, up to 5 redirects
# followed manually — this stdlib has no built-in redirect support).
# Specs and alternative backends swap it through `Http.use_fetcher`.
#
#   Egui::Http.get("https://example.com/api") do |result|
#     if result.success?
#       puts result.body.size
#     end
#   end
#
# `UrlImage` below is the cache entry of the image-by-URL pipeline
# (`Context#load_image_url`, widgets/remote_image.cr): the worker
# fiber only parks raw BYTES + error between frames; decode and the
# GPU upload happen lazily inside a frame, on the sokol thread.

require "http/client"
require "uri"

module Egui
  module Http
    # One finished request: `status` 0 means the fetch never completed
    # (DNS failure, timeout — see `error`); `body` is the raw response
    # bytes (safe for binary payloads).
    record Result, status : Int32, body : Bytes, error : String? do
      # True for a 2xx answer without transport error.
      def success? : Bool
        error.nil? && status >= 200 && status < 300
      end
    end

    @@pending = 0
    @@delivered = 0

    # The transport behind #get — the stdlib implementation by default.
    class_property fetcher : Proc(String, HTTP::Headers?, Result) =
      ->(url : String, headers : HTTP::Headers?) { default_fetch(url, headers) }

    # Install a custom transport (spec seam; native-platform ports).
    def self.use_fetcher(&block : String, HTTP::Headers? -> Result) : Nil
      @@fetcher = block
    end

    # GET `url` in a worker fiber; `on_done` fires between frames (see
    # the module comment). One fiber per call — deduplication is the
    # caller's business (the URL image cache does it).
    def self.get(url : String, headers : HTTP::Headers? = nil,
                 &on_done : Result ->) : Nil
      fetcher = @@fetcher
      @@pending += 1
      spawn do
        result = fetcher.call(url, headers)
        @@pending -= 1
        @@delivered += 1
        on_done.call(result)
        Egui::Runtime.wake.try &.call
      end
    end

    # True while at least one fetch is in flight.
    def self.pending? : Bool
      @@pending > 0
    end

    # Legacy backend crutch: one bounded scheduler pass per frame so
    # worker fibers advance inside sapp_run's blocking C loop. The
    # detached backend never calls this — its fibers run between
    # frames on their own.
    def self.pump_pass : Nil
      if @@pending > 0
        select
        when timeout(1.milliseconds)
        end
      end
    end

    # Consume the completed-fetch count — their callbacks already
    # ran; the count only tells the backend a full frame must follow.
    def self.take_delivered : Int32
      n = @@delivered
      @@delivered = 0
      n
    end

    # --- stdlib transport ------------------------------------------------

    def self.default_fetch(url : String, headers : HTTP::Headers?) : Result
      # Many CDNs answer 403/400 to a UA-less request; send one unless
      # the caller set their own (copy first — never mutate caller's).
      unless headers.try(&.["User-Agent"]?)
        headers = (headers || HTTP::Headers.new).dup
        headers["User-Agent"] = "egui-cr/0.2"
      end
      current = url
      redirects = 0
      loop do
        location = nil
        status = 0
        body = Bytes.empty
        HTTP::Client.get(current, headers) do |response|
          status = response.status.code
          if response.status.redirection? &&
             (loc = response.headers["Location"]?)
            location = loc
          else
            body = response.body_io.getb_to_end
          end
        end
        if location
          return Result.new(status, Bytes.empty,
            "too many redirects") if (redirects += 1) > 5
          current = URI.parse(current).resolve(location).to_s
          next
        end
        return Result.new(status, body, nil)
      end
    rescue ex : Exception
      Result.new(0, Bytes.empty, ex.message || ex.class.to_s)
    end

    # One URL's image slot in the Context cache. State machine:
    #
    #   :loading → :fetched → :ready | :failed
    #
    # The worker fiber transitions :loading→:fetched (raw bytes parked
    # between frames); the in-frame decode path (:fetched→:ready) runs
    # on the sokol thread — GPU uploads never happen off-thread.
    class UrlImage
      property state : Symbol = :loading
      property bytes : Bytes? = nil
      property error : String? = nil
      property texture_id : UInt64 = 0_u64
      property size : Vec2? = nil

      def loading? : Bool
        state == :loading || state == :fetched
      end
    end
  end
end
