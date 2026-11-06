require "../../src/egui"

# ═══ BACKEND ПРИЛОЖЕНИЯ (system_monitor) ═══════════════════════════
# MVC-разрез (plans/frontend-backend-split.md фаза 4): сэмплирование
# счётчиков — ФОНОВАЯ РАБОТА по §6.1 — джоба Mvc::AsyncJob, запущенная
# контроллером (POST → джоб-хендл по id), а не тик в кадре. Джоба
# сэмплирует порт метрик раз в интервал и диспатчит сэмпл в State
# («джоба — dispatch результата фоновой работы», §7); фронт никогда не
# трогает источник. Контроль (start/stop/pause/resume) — контроллером
# по id, повторный старт — 409 (план §6.1).
#
# Порт метрик: прод ставит sysinfo-сэмплер в ТОЧКЕ ВХОДА (файл
# examples/system_monitor.cr), спеки — детерминированный фейк; этот
# файл driver-free и dep-free.

module SysMon
  # Снимок счётчиков на момент взятия (значения, не скорости —
  # скорости сети уже в B/s посчитал источник).
  struct Sample
    property cores : Array(Float64) = [] of Float64
    property ram_used_kb : Int64 = 0_i64
    property ram_total_kb : Int64 = 0_i64
    property rx_b_s : Float64 = 0.0
    property tx_b_s : Float64 = 0.0
  end
end

class SysMonRepo
  @@job : Egui::Mvc::AsyncJob?

  # Порт источника метрик: прод — sysinfo (точка входа), спеки — фейк.
  class_property sampler : (-> SysMon::Sample?)?

  def self.job : Egui::Mvc::AsyncJob?
    @@job
  end

  # Активна ли выборка (queued/running/paused; cancelled/done — нет).
  def self.active? : Bool
    if j = @@job
      {:queued, :running, :paused}.includes?(j.status)
    else
      false
    end
  end

  def self.start!(interval : Float64) : String
    job = SamplerJob.new(interval)
    job.perform_later
    @@job = job
    job.id
  end

  def self.stop! : Nil
    @@job.try &.cancel!
  end

  def self.pause! : Nil
    @@job.try &.pause!
  end

  def self.resume! : Nil
    @@job.try &.resume!
  end

  # Слайс стора: последний сэмпл (фронт читает "metrics/latest",
  # подписка/версия — repaint-триггер).
  def self.wire : Nil
    Egui::Mvc.state.on("metrics/sample") do |payload, w|
      w.set("metrics/latest", payload)
    end
  end

  def self.boot! : Nil
    wire
  end

  # Джоба сэмплирования: бесконечный цикл порт → dispatch; каденс —
  # nap (сон срезами, пауза/отмена срабатывают В ожидании).
  class SamplerJob < Egui::Mvc::AsyncJob
    def initialize(@interval : Float64)
      super()
    end

    def perform : Egui::Mvc::StateValue?
      sampler = SysMonRepo.sampler ||
                 raise "set SysMonRepo.sampler (the entry point installs the sysinfo one)"
      loop do
        if sample = sampler.call
          Egui::Mvc.state.dispatch("metrics/sample", Egui::Mvc.to_json_any({
            "cpu"         => sample.cores,
            "ram_used_kb" => sample.ram_used_kb,
            "ram_total_kb" => sample.ram_total_kb,
            "rx"          => sample.rx_b_s,
            "tx"          => sample.tx_b_s,
          }))
        end
        nap(@interval)
      end
    end
  end
end

# --- Контроллер ---------------------------------------------------------------

class MetricsController < Egui::Mvc::Controller
  # POST /metrics/sampling — запустить выборку (202: работа пошла,
  # результат поедет срезом, не ответом). Повторный старт — 409.
  def create(request)
    return Egui::Mvc::Response.new(409,
      Egui::Mvc.to_json_any({"error" => "already sampling"})) if SysMonRepo.active?

    interval = request.body["interval"]?.try(&.as_f?) || 1.0
    id = SysMonRepo.start!(interval)
    Egui::Mvc::Response.new(202, Egui::Mvc.to_json_any({"id" => id}))
  end

  # DELETE /metrics/sampling — отменить джобу.
  def destroy(request)
    SysMonRepo.stop!
    {"stopped" => true}
  end

  # POST /metrics/sampling/pause | /resume.
  def pause(request)
    SysMonRepo.pause!
    {"paused" => true}
  end

  def resume(request)
    SysMonRepo.resume!
    {"resumed" => true}
  end

  actions
end

SYSMON_ROUTES = Egui::Mvc::Router.new.draw do |r|
  r.post "/metrics/sampling", MetricsController, "create"
  r.post "/metrics/sampling/pause", MetricsController, "pause"
  r.post "/metrics/sampling/resume", MetricsController, "resume"
  r.delete "/metrics/sampling", MetricsController, "destroy"
end
