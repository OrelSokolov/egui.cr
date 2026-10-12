# IME e2e test app (ANDROID_SUPPORT_PLAN.md, phase 5): three text
# fields (plain / password / multiline) to drive the Android soft
# keyboard through the InputConnection bridge.
#
# Build (host):  ANDROID_PLATFORM=33 crystal build --cross-compile \
#                 --target=aarch64-linux-android -o ime_test.o ime_test.cr
# APK:           tmp/android/build_apk.sh <objdir>/ime_test.o

require "../../src/egui/backend_selector"

class ImeTestApp < Egui::App
  @plain = ""
  @secret = ""
  @multi = ""

  def update(ctx : Egui::Context) : Nil
    {% if flag?(:android) %}
      t = ctx.input.text
      egui_android_log("app frame: text=#{t.inspect} plain=#{@plain.inspect} wants_ti=#{ctx.wants_text_input?}") unless t.empty?
    {% end %}
    ctx.central_panel do |ui|
      ui.heading("IME test")
      ui.label("plain: #{@plain.inspect}")
      ui.text_edit_singleline(@plain, hint: "single line") { |t|
        egui_android_log("on_change plain: #{t.inspect}")
        @plain = t
      }
      ui.separator
      ui.label("secret: #{@secret.size} chars")
      ui.text_edit_singleline(@secret, hint: "password", password: true) { |t| @secret = t }
      ui.separator
      ui.label("multiline: #{@multi.inspect}")
      ui.textarea(@multi, hint: "multiline", rows: 4) { |t| @multi = t }
    end
  end
end

Egui.run(ImeTestApp.new, title: "egui-cr — ime test")
