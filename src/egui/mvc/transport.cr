# Transport — единственная дыра между frontend и backend'ом приложения
# (plans/frontend-backend-split.md §5). Frontend умеет ТОЛЬКО: читать
# store и звать `request`; он не знает ни одного типа backend'а, кроме
# конверта Request/Response.
#
# Ответ — всегда колбэком, никогда синхронно: блокировка на
# фрейм-файбере = замороженное окно. Ошибки никогда не райзят —
# статус всегда в Response (4xx/5xx).
#
# InProcessTransport (egui-реализация контракта) повторяет контракт
# Egui::Http (src/egui/http.cr): конверт летит по ссылке (ноль
# сериализации), обработка — в своём рабочем файбере, `on_done`
# доставляется МЕЖДУ кадрами (файберы двигает планировщик, который
# on_frame качает перед begin_frame) + стук в дверной колокольчик
# Runtime.wake (detached-цикл) → следующий кадр видит результат.

module Egui
  module Mvc
    # Контракт: увезти Request, доставить Response. positron'овский
    # BridgeTransport (JSON через мост WebView) реализует тот же шов.
    abstract class Transport
      abstract def call(request : Request, &on_done : Response ->) : Nil
    end

    # egui-реализация:_router в том же процессе, ноль сериализации.
    class InProcessTransport < Transport
      getter router : Router

      def initialize(@router : Router = Router.new)
      end

      def call(request : Request, &on_done : Response ->) : Nil
        Mvc.request_started
        delivery = ->do
          response = @router.handle(request)
          Mvc.request_finished
          on_done.call(response)
          Egui::Driver::Base.current.try &.wake
        end
        # Запрос из конструктора приложения прилетает ДО рамочной петли:
        # спавн лёг бы на контекст вызвавшего (main), а под инвертированным
        # macOS-циклом main отдан AppKit и его планировщик больше не
        # крутится — файбер умер бы в очереди (наблюдалось как «то ядра,
        # то нету» у system_monitor: авто-старт выборки не исполнялся).
        # Паркуем доставку: первый кадровый проход (#unpark_requests из
        # обеих рамочных точек драйвера) переспавнит её на живом контексте.
        if Mvc.frame_loop_live?
          spawn &delivery
        else
          Mvc.park_request &delivery
        end
      end
    end

    # Регистр слоя: транспорт по умолчанию (разводка Egui.run ставит
    # свой; спеки фронтенда подменяют на ScriptedTransport, §9).
    class_property transport : Transport = InProcessTransport.new

    # Стор приложения. Интерим-разводка (как транспорт): пока Egui.run
    # не раздаёт State адресно (App API, §12), слой живёт здесь —
    # контроллеры/джобы пишут через Mvc.state.dispatch, фронтенду
    # отдают как Mvc.state_view (тип StateView, без dispatch).
    class_property state : State = State.new

    def self.state_view : StateView
      state
    end

    @@inflight = 0
    @@delivered = 0
    # Worker-fiber bookkeeping (InProcessTransport today; a scripted
    # test transport may reuse the same counters).
    def self.request_started : Nil
      @@inflight += 1
    end

    def self.request_finished : Nil
      @@inflight -= 1
      @@delivered += 1
    end

    # True while at least one request is in flight.
    def self.pending? : Bool
      @@inflight > 0
    end

    # Deliveries parked before the frame loop existed (requests fired
    # from app constructors — see InProcessTransport#call) and the flag
    # marking the loop alive.
    @@parked = [] of Proc(Nil)
    @@frame_loop_live = false

    def self.frame_loop_live? : Bool
      @@frame_loop_live
    end

    def self.park_request(&delivery : Proc(Nil)) : Nil
      @@parked << delivery
    end

    # Re-spawn parked request deliveries on the CALLING context — both
    # driver frame entries (the legacy on_frame pump and the detached
    # produce loop) call this once per frame, so the context here is
    # always a live one. First call also marks the loop alive: requests
    # arriving after it spawn directly, as before.
    def self.unpark_requests : Nil
      @@frame_loop_live = true
      return if @@parked.empty?
      parked = @@parked
      @@parked = [] of Proc(Nil)
      parked.each { |delivery| spawn &delivery }
    end

    # Legacy backend crutch (Egui::Http.pump_pass contract): one
    # bounded scheduler pass per frame so worker fibers advance inside
    # sapp_run's blocking C loop (macOS/Linux legacy, Android, iOS).
    # The detached produce loop never sleeps here — it only drains the
    # parked requests (#unpark_requests); its fibers run between
    # frames on their own.
    def self.pump_pass : Nil
      unpark_requests
      if @@inflight > 0
        select
        when timeout(1.milliseconds)
        end
      end
    end

    # Consume the completed-request count — their callbacks already
    # ran; the count only tells the backend a full frame must follow.
    def self.take_delivered : Int32
      n = @@delivered
      @@delivered = 0
      n
    end

    # Иммутабельный конверт из именованных аргументов сахара
    # `Egui.request "POST", "/posts", title: "…"`.
    def self.to_json_any(value) : JSON::Any
      JSON::Any.new(JSON::PullParser.new(value.to_json))
    end
  end

  # Frontend-facing API (план §5) — запрос, как Positron.request в JS:
  #
  #   Egui.request "POST", "/posts", title: "Привет", tags: ["a"] do |resp|
  #     # ошибки никогда не райзят — всегда status в resp
  #   end
  #
  # Body — либо именованные аргументы (сериализуются в JSON-объект),
  # либо готовый JSON::Any. Query — инлайном в path ("GET", "/x?a=1").
  # Никогда не блокирует и не райзит; результат приезжает между
  # кадров через on_done.
  def self.request(method : String, path : String, **body,
                   &on_done : Mvc::Response ->) : Nil
    Mvc.transport.call(
      Mvc::Request.new(method, path, body: Mvc.to_json_any(body)),
      &on_done)
  end

  def self.request(method : String, path : String, body : JSON::Any,
                   &on_done : Mvc::Response ->) : Nil
    Mvc.transport.call(
      Mvc::Request.new(method, path, body: body), &on_done)
  end
end
