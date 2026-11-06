require "spec"
require "../src/egui"

# Джобы §6.1 (src/egui/mvc/async.cr): контроль (pause/resume/cancel),
# кооперация (checkpoint!/nap/progress), наблюдение (статусы пишет
# раннер, проекция — срез "jobs/<id>" в State). Файбер джобы уступает
# в sleep — поэтому каждый «pump» = сон 1мс основной файбой.

# Конечная джоба: N тактов с nap-уступками, прогресс по такту.
class AsyncSpecCountingJob < Egui::Mvc::AsyncJob
  getter ticks = 0

  def initialize(@max : Int32)
    super()
  end

  def perform : Egui::Mvc::StateValue?
    @max.times do |i|
      progress((i + 1).to_f64 / @max)
      @ticks += 1
      nap(0.001)
    end
    Egui::Mvc.to_json_any({"n" => @max})
  end
end

# Бесконечный сон срезами: чистая мишень для pause/cancel.
class AsyncSpecNapJob < Egui::Mvc::AsyncJob
  def perform : Egui::Mvc::StateValue?
    loop { nap(0.05) }
  end
end

# Плотный шквал progress без уступок — проверка троттлина проекции.
class AsyncSpecBurstJob < Egui::Mvc::AsyncJob
  def perform : Egui::Mvc::StateValue?
    50.times { |i| progress(i / 50.0) }
    nil
  end
end

class AsyncSpecFailingJob < Egui::Mvc::AsyncJob
  def perform : Egui::Mvc::StateValue?
    raise "kaput"
  end
end

def async_pump(job : Egui::Mvc::AsyncJob, target : Symbol, limit = 500) : Nil
  limit.times do
    sleep 1.millisecond
    break if job.status == target
  end
end

describe "Mvc::AsyncJob" do
  it "lifecycle: queued → running → done, result в конверте" do
    job = AsyncSpecCountingJob.new(3)
    job.status.should eq :queued
    job.perform_later
    async_pump job, :done

    job.status.should eq :done
    job.ticks.should eq 3
    job.progress.should eq 1.0
    job.result.not_nil!["n"].as_i.should eq 3

    slice = Egui::Mvc.state["jobs/#{job.id}"]
    slice["status"].as_s.should eq "done"
    slice["progress"].as_f.should eq 1.0
    slice["result"]["n"].as_i.should eq 3
  end

  it "cancel: Cancelled на ближайшей точке кооперации" do
    job = AsyncSpecNapJob.new.perform_later
    async_pump job, :running
    job.cancel!
    async_pump job, :cancelled

    job.status.should eq :cancelled
    job.result.should be_nil
    Egui::Mvc.state["jobs/#{job.id}"]["status"].as_s.should eq "cancelled"
  end

  it "cancel до первого такта: джоба не выполняется" do
    job = AsyncSpecNapJob.new.perform_later
    job.cancel!
    async_pump job, :cancelled
    job.status.should eq :cancelled
  end

  it "pause/resume: парковка в nap, снятие — и продолжение" do
    job = AsyncSpecNapJob.new.perform_later
    async_pump job, :running

    job.pause!
    async_pump job, :paused
    job.status.should eq :paused
    Egui::Mvc.state["jobs/#{job.id}"]["status"].as_s.should eq "paused"

    job.resume!
    async_pump job, :running
    job.status.should eq :running

    job.cancel!
    async_pump job, :cancelled
  end

  it "pause на не-running — no-op" do
    job = AsyncSpecCountingJob.new(1)
    job.pause!
    job.status.should eq :queued
    job.perform_later
    async_pump job, :done
    job.status.should eq :done
  end

  it "троттлинг проекции прогресса (~10 Гц)" do
    projections = [] of Float64
    job = AsyncSpecBurstJob.new
    Egui::Mvc.state.subscribe("jobs/#{job.id}") { |v| projections << v["progress"].as_f }
    job.perform_later
    async_pump job, :done

    # 50 плотных вызовов progress → проекции только :running и финал
    # (шквал укладывается в окно троттла с огромным запасом).
    projections.should eq [0.0, 1.0]
  end

  it "фейл: статус failed, ошибка в конверте" do
    job = AsyncSpecFailingJob.new.perform_later
    async_pump job, :failed

    job.status.should eq :failed
    slice = Egui::Mvc.state["jobs/#{job.id}"]
    slice["status"].as_s.should eq "failed"
    slice["error"].as_s.should eq "kaput"
  end
end
