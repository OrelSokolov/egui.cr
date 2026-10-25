# egui-cr: image-by-URL widget + the HTTP client behind it.
#
# A grid of remote images (spinner placeholders while they load —
# each URL fetched ONCE per Context, shared by every widget showing
# it) and a direct Egui::Http.get demo row. Needs network access.

require "../src/egui/backend_selector"

class RemoteImageApp < Egui::App
  # (picked to be reachable without a browser fingerprint — picsum
  # and friends 403 whole networks from CDNs; the last one answers a
  # real 404 — the failed-state demo)
  URLS = [
    "https://httpbin.org/image/png",
    "https://httpbin.org/image/jpeg",
    "https://www.google.com/images/branding/googlelogo/2x/googlelogo_color_272x92dp.png",
    "https://httpbin.org/status/404",
  ]

  @api_answer : String? = nil
  @api_fetching = false

  def update(ctx : Egui::Context) : Nil
    ctx.central_panel do |ui|
      ui.heading("Images by URL")
      ui.label("placeholder + spinner while loading; 404 → failed slot")

      URLS.each do |url|
        ui.remote_image(url, Egui::Vec2.new(320.0, 200.0))
        # The slot's lifecycle is public: apps can react to it.
        case ctx.url_image_state(url)
        when :failed
          ui.label("failed: #{ctx.url_images[url].error}")
        end
        ui.add(Egui::Separator.new)
      end

      ui.heading("Direct HTTP")
      if ui.button("GET https://httpbin.org/uuid").clicked?
        @api_answer = nil
        @api_fetching = true
        # Runs in its own fiber; the callback fires between frames.
        Egui::Http.get("https://httpbin.org/uuid") do |result|
          @api_fetching = false
          @api_answer = result.success? ?
            String.new(result.body) : (result.error || "HTTP #{result.status}")
        end
      end
      if @api_fetching
        ui.add(Egui::Spinner.new)
      else
        ui.label(@api_answer || "—")
      end
    end
  end
end

Egui.run(RemoteImageApp.new, title: "egui-cr — remote image",
  inspector: :hidden)
