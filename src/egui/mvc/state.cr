# Стор приложения (plans/frontend-backend-split.md §7): State —
# единственный владелец данных, переживающих кадр. ЗАПИСЬ = событие
# (`dispatch` — интерфейс действий из редакса), чтение — через
# StateView (модуль-намерение, который State включает). Имена
# зафиксированы планом: интерфейс = намерение, класс = реализация.
#
# Кто пишет / читает (§7):
#   фронтенд   — НИКОГДА не пишет; читает всегда (рендер из StateView)
#   контроллер — dispatch (результат действия); читает (решения)
#   джоба      — dispatch (результат фоновой работы) — с фазой джоб
#   порты      — dispatch (внешние события)
#   транспорт  — ничего: только возит request/response
#
# Механика записи: обработчик действия получает Writer, валидный
# ТОЛЬКО внутри dispatch — обойти событие физически нельзя (нечем
# писать: у State нет публичных сеттеров). Внутри — словарь срезов с
# версионируемыми ячейками (семантика сигналов: версия растёт на
# запись, виджет сверяет дешёво), лог действий — кольцо для
# инспектора/time-travel (варится в core — инспектор egui его читает).
#
# Значение среза — JSON::Any: тот же конверт, что Request/Response —
# positron-мост сериализует без конверсии, egui возит по ссылке.
# Появится доказанная нужда в типизированных ячейках — слой сядет
# поверх (план: генерализация от трёх типов, не от одного).

module Egui
  module Mvc
    alias StateValue = JSON::Any

    # Намерение «читать состояние»: то, что попадает во фронтенд.
    # dispatch в нём отсутствует — автодополнение видит только [] и
    # subscribe. Реализация (State) включает модуль и добавляет
    # запись СВОИМ методом.
    module StateView
      abstract def [](key : String) : StateValue
      abstract def []?(key : String) : StateValue?
      abstract def subscribe(key : String, &listener : StateValue ->) : Nil
    end

    class State
      include StateView

      alias Payload = JSON::Any
      alias Handler = Payload, Writer ->

      LOG_CAP = 256

      # Писатель, передаваемый обработчику действия: валиден только на
      # время dispatch. Отдельный объект, а не protected-метод State,
      # чтобы «нечем писать» было правдой типов, а не конвенцией.
      class Writer
        def initialize(@state : State)
        end

        def set(key : String, value : StateValue) : Nil
          @state.write(key, value)
        end

        def delete(key : String) : Nil
          @state.delete(key)
        end
      end

      def initialize
        @cells = {} of String => StateValue
        @versions = {} of String => UInt64
        @listeners = {} of String => Array(StateValue ->)
        @handlers = {} of String => Handler
        @log = Deque({String, Payload}).new
      end

      # Зарегистрировать обработчик действия (редьюсер без чистоты:
      # пишет в этот же стор; стор один, гонок нет — план §7).
      def on(action : String, &handler : Handler) : Nil
        @handlers[action] = handler
      end

      # ЗАПИСЬ = событие: выполняет обработчик `action` с payload,
      # кладёт действие в лог, будит драйвер (джобы и порты пишут ВНЕ
      # доставки запросов — их проекцию в кадр должен кто-то пнуть;
      # колбэки транспорта уже будят петлю доставкой ответа).
      def dispatch(action : String, payload : Payload = EMPTY_BODY) : Nil
        @log << {action, payload}
        shift_log
        @handlers[action]?.try &.call(payload, Writer.new(self))
        Egui::Driver::Base.current.try &.wake
      end

      # Лог действий (кольцо LOG_CAP): еда инспектора/time-travel.
      def log : Deque({String, Payload})
        @log
      end

      # --- StateView (чтение) --------------------------------------------

      def [](key : String) : StateValue
        @cells[key]
      end

      def []?(key : String) : StateValue?
        @cells[key]?
      end

      # Подписка на срез: колбэк с новым значением, когда оно ИЗМЕНИЛОСЬ
      # (присвоение той же величины — не событие). egui-потребитель —
      # repaint/реактивная ячейка; positron-потребитель — патч JS-зеркала
      # (мост становится просто подписчиком стора, §5).
      def subscribe(key : String, &listener : StateValue ->) : Nil
        (@listeners[key] ||= [] of (StateValue ->)) << listener
      end

      # Версия среза: растёт на каждую запись. Виджет помнит виденную
      # версию и проверяет одной сверкой — прицельная перерисовка без
      # глубокого сравнения значений.
      def version(key : String) : UInt64
        @versions[key]? || 0_u64
      end

      def keys : Array(String)
        @cells.keys
      end

      # --- внутреннее ------------------------------------------------------

      # protected: вызов допустим из типов того же пространства имён —
      # Writer ниже; снаружи Mvc граница видна типами (StateView без записи).
      protected def write(key : String, value : StateValue) : Nil
        return if @cells[key]? == value
        @cells[key] = value
        @versions[key] = version(key) + 1
        if list = @listeners[key]?
          list.each &.call(value)
        end
      end

      protected def delete(key : String) : Nil
        return unless @cells.has_key?(key)
        @cells.delete(key)
        @versions[key] = version(key) + 1
        if list = @listeners[key]?
          list.each &.call(Mvc::EMPTY_BODY)
        end
      end

      private def shift_log : Nil
        while @log.size > LOG_CAP
          @log.shift
        end
      end
    end
  end
end
