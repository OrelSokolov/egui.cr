require "spec"
require "../examples/system_monitor_components/backend"

# system_monitor MVC (фаза 4): сэмплирование — джоба Mvc::AsyncJob
# (§6.1). Здесь проверяется контрольная плоскость: старт по роуту,
# сэмплы срезом "metrics/latest" от ФЕЙКА порта метрик, 409 на
# повторный старт, pause/cancel. Файлы примера не требуют sysinfo —
# спека ставит детерминированный сэмплер.

def sysmon_pump_requests(limit = 50) : Nil
  limit.times do
    Egui::Mvc.pump_pass
    break unless Egui::Mvc.pending?
  end
end

def sysmon_call(method : String, path : String) : Egui::Mvc::Response
  got = [] of Egui::Mvc::Response
  Egui::Mvc.transport.call(Egui::Mvc::Request.new(method, path)) { |r| got << r }
  sysmon_pump_requests
  got.first.not_nil!
end

def sysmon_wait_job(job : Egui::Mvc::AsyncJob?, target : Symbol, limit = 500) : Nil
  limit.times do
    sleep 1.millisecond
    break if job.try(&.status) == target
  end
end

describe "system_monitor MVC" do
  before_each do
    SysMonRepo.boot!
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(SYSMON_ROUTES)
    # Фейк источника: фиксированные метрики, одинаковые каждый сэмпл.
    SysMonRepo.sampler = -> : SysMon::Sample? do
      s = SysMon::Sample.new
      s.cores = [25.0, 75.0]
      s.ram_used_kb = 2_i64 * 1024 * 1024
      s.ram_total_kb = 8_i64 * 1024 * 1024
      s.rx_b_s = 2048.0
      s.tx_b_s = 512.0
      s
    end
  end

  after_each do
    SysMonRepo.stop!
    sysmon_wait_job SysMonRepo.job, :cancelled
  end

  it "старт: 202 + сэмплы едут срезом metrics/latest" do
    resp = sysmon_call "POST", "/metrics/sampling"
    resp.status.should eq 202
    job_id = resp.body["id"].as_s

    # Джоба сэмплирует ВНЕ доставки запроса: ждём первый сэмпл.
    sample = nil.as(JSON::Any?)
    500.times do
      sleep 1.millisecond
      sample = Egui::Mvc.state["metrics/latest"]?
      break if sample
    end
    sample.should_not be_nil
    sample.not_nil!["cpu"].as_a.map(&.as_f).should eq [25.0, 75.0]
    sample.not_nil!["ram_total_kb"].as_i64.should eq 8_i64 * 1024 * 1024

    # Проекция джобы: конверт в "jobs/<id>".
    Egui::Mvc.state["jobs/#{job_id}"]["status"].as_s.should eq "running"
  end

  it "повторный старт — 409" do
    sysmon_call("POST", "/metrics/sampling").status.should eq 202
    sysmon_call("POST", "/metrics/sampling").status.should eq 409
  end

  it "pause → срез джобы paused, resume → running" do
    sysmon_call "POST", "/metrics/sampling"
    job = SysMonRepo.job.not_nil!

    job.pause!
    sysmon_wait_job job, :paused
    job.status.should eq :paused

    job.resume!
    sysmon_wait_job job, :running
    job.status.should eq :running
  end

  it "стоп: отмена, сэмплы замирают" do
    sysmon_call("POST", "/metrics/sampling").status.should eq 202
    job = SysMonRepo.job.not_nil!

    resp = sysmon_call "DELETE", "/metrics/sampling"
    resp.ok?.should be_true
    sysmon_wait_job job, :cancelled
    job.status.should eq :cancelled

    SysMonRepo.active?.should be_false
    # После отмены старт снова возможен.
    sysmon_call("POST", "/metrics/sampling").status.should eq 202
  end
end
