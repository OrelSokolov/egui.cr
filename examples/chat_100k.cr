# egui-cr chat/100k — the live stress variant of the chat example:
# the same ChatApp, but the LOG is pre-seeded with 100k agent replies
# (a realistic role mix, the same append path the live app uses), so
# the two-zone model can be checked by hand over a real-size history:
# scrolling, the stick-to-bottom log, the active zone building itself
# over the input, streaming into the log. Headless numbers:
# bench/chat_bench.cr.

require "../src/egui/driver_selector"
require "./chat_components/chat_app"
require "./chat_components/pick_font"

N = (ENV["N"]? || "100000").to_i

class SeededChatApp < ChatApp
  # Fill the LOG with a realistic role mix (user / assistant / tool
  # headers+results / think / CI), like a long working session.
  def seed(entries : Int32) : Nil
    entries.times do |i|
      role = case i % 7
             when 0 then :user
             when 1 then :assistant
             when 2 then :tool_run
             when 3 then :tool_result
             when 4 then :think
             when 5 then :ci
             else        :user
             end
      text = case role
             when :user
               "добавь поле поиска в таблицу и почини валидацию формы ##{i}"
             when :assistant
               "Готово: индекс перестроен, тесты зелёные, счётчик ##{i}"
             when :tool_run
               "Выполнена команда: bash — crystal spec spec/chat_spec.cr ##{i}"
             when :tool_result
               "→ 24 examples, 0 failures, 1.2s ##{i}"
             when :think
               "Обдумано · 0.9 с ##{i}"
             else
               "CI passed ✓ · 2.5 с ##{i}"
             end
      append(role, text)
    end
  end
end

pick_terminal_font

app = SeededChatApp.new
app.seed(N)
Egui.run(app, title: "h2code — chat · #{N} ответов (двухзонная модель)",
  width: 760, height: 580, inspector: :hidden)
