# Джобы (plans/frontend-backend-split.md §6.1): фоновая работа —
# контроллер ПОПРОСИЛ (POST /jobs → 202), джоба выполняется ВНЕ
# доставки запросов и проецирует себя в State («джоба — dispatch
# результата фоновой работы», §7). Пользователь управляет ею по id:
# pause/resume/cancel.
#
# Поверхностный контракт §6.1 в три слоя:
#   контроль     pause! / resume! / cancel! — зовут извне (контроллер,
#                меню), НИКОГДА сама джоба
#   кооперация   checkpoint! / nap / progress — зовет только perform:
#                контроль срабатывает в этих точках (кооперативная
#                отмена — однопоточная петля не прерывает никого)
#   наблюдение   status/progress/result/error — статусы пишет РАННЕР
#                (файбер-обвязка ниже), джоба трогает только progress;
#                проекция — срез "jobs/<id>" через dispatch + wake
#                драйвера (это и есть UIAdapter из §6.1)
#
# Статусы: :queued → :running → (:paused ⇄ :running)* →
# (:done | :failed | :cancelled).
#
# Это лёгкий v1, живущий в egui: ретраи, пулы, сериализация и
# адаптеры очередей — дело общего шарда active_job_cr (репозиторий
# crails, `bench/crails_jobs`) и фазы 6 (tentacles); здесь только
# контракт, на который примеры (system_monitor) опираются уже сейчас.
# Механика паузы честной парковкой файбера не страдает: v1 крутит
# 20мс-циклы сна в checkpoint! (допустимо планом §6.1), cancel
# поднимает Cancelled на ближайшей точке кооперации и НЕ ретраится.

module Egui
  module Mvc
    # Эпоха часов джоб: у монотонных инстантов нет абсолютных секунд,
    # считаем от загрузки модуля (нужны только разности).
    CLOCK0 = Time.instant

    abstract class AsyncJob
      # Отмена — не ошибка вины джобы: ретраить её нельзя, но и
      # глотать молча нельзя — perform видит её как исключение.
      class Cancelled < Exception
      end

      getter id : String
      getter status : Symbol = :queued
      getter progress : Float64 = 0.0
      getter result : StateValue?
      getter error : String?

      @pause_requested = false
      @cancel_requested = false
      @last_projection = -1.0e18_f64
      @@seq = 0_u64

      def initialize(@id : String = AsyncJob.next_id)
      end

      def self.next_id : String
        @@seq += 1
        "job-#{@@seq}"
      end

      # Тело джобы. Кооперация — checkpoint!/nap/progress; управление
      # статусом запрещено (контроль пишет раннер, джоба — результат).
      abstract def perform : StateValue?

      # Поставить и запустить: файбер, стартующий при первой уступке.
      # Защита от двойного запуска — на стороне контроллера (409 на
      # повторный POST, план §6.1), джоба себя не охраняет.
      def perform_later : self
        spawn run
        self
      end

      # --- контроль (наружу) ------------------------------------------------

      def pause! : Nil
        return unless @status == :running
        @pause_requested = true
      end

      def resume! : Nil
        @pause_requested = false
      end

      def cancel! : Nil
        @cancel_requested = true
        @pause_requested = false
      end

      # --- кооперация (только из perform) ------------------------------------

      # Точка кооперации: здесь джоба замирает на паузе и узнаёт об
      # отмене. Пауза без честной парковки (v1): 20мс-циклы сна, пока
      # контроллер не снимет её; отмена поднимает Cancelled.
      def checkpoint! : Nil
        if @pause_requested && !@cancel_requested
          @status = :paused
          project
          while @pause_requested && !@cancel_requested
            sleep 20.milliseconds
          end
          @status = :running
          project
        end
        raise Cancelled.new("cancelled") if @cancel_requested
      end

      # Сон срезами ~25мс: пауза/отмена срабатывают В ожидании, не
      # спустя его (в отличии от голого sleep, который не прервать).
      def nap(seconds : Float64) : Nil
        deadline = clock + seconds
        while (remaining = deadline - clock) > 0
          sleep({remaining, 0.025}.min.seconds)
          checkpoint!
        end
      end

      # Прогресс 0..1: значение пишется всегда, ПРОЕКЦИЯ троттлится
      # (~10 Гц — чаще кадра всё равно никто не смотрит; финальную
      # проекцию делает раннер при завершении).
      def progress(value : Float64) : Nil
        @progress = value.clamp(0.0, 1.0)
        return unless @progress >= 1.0 || clock - @last_projection >= 0.1
        @last_projection = clock
        project
      end

      # --- раннер -------------------------------------------------------------

      private def run : Nil
        @status = :running
        @last_projection = clock
        project
        begin
          @result = perform
          @status = :done
          @progress = 1.0
        rescue ex : Cancelled
          @status = :cancelled
        rescue ex : Exception
          @error = ex.message || ex.class.name
          @status = :failed
        end
        project
      end

      # Проекция в State: срез "jobs/<id>" — конверт джобы целиком.
      # Хендлер переустанавливается на каждом вызове: Mvc.state —
      # class_property, приложение может подменить экземпляр (своей
      # регистрации в момент require не хватит). Побочный wake делает
      # сам dispatch (§7).
      private def project : Nil
        payload = Mvc.to_json_any({
          "id"       => id,
          "status"   => @status.to_s,
          "progress" => @progress,
          "result"   => @result,
          "error"    => @error,
        })
        state = Mvc.state
        state.on("job/update") do |p, w|
          w.set("jobs/#{p["id"].as_s}", p)
        end
        state.dispatch("job/update", payload)
      end

      private def clock : Float64
        (Time.instant - Mvc::CLOCK0).total_seconds
      end
    end
  end
end
