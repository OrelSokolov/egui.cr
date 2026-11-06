# System monitor demo — GNOME System Monitor-style live scrolling
# graphs: one per CPU core, RAM, and network (receiving/sending).
# The graphs scroll CONTINUOUSLY (each sample is tagged with its
# monotonic timestamp and x = right edge - age, so the curve slides
# every frame, not once per sample) with an EKG-style time grid.
#
# Data source: sysinfo.cr (https://github.com/OrelSokolov/sysinfo.cr),
# a DEVELOPMENT dependency of egui-cr: demos may require it, the
# framework itself never does (see shard.yml). RAM, per-core busy% and
# network rates all come from there, so the demo is cross-platform
# (Linux / macOS / Windows); on other platforms the graphs stay flat
# at zero.
#
# MVC-миграция (plans/frontend-backend-split.md фаза 4): сэмплирование
# — джоба Mvc::AsyncJob (§6.1), контрольная плоскость —
# examples/system_monitor_components/backend.cr, вид —
# system_monitor_components/system_monitor_app.cr. Этот файл — точка
# входа: sysinfo-сэмплер порта метрик, запуск.

require "../src/egui/driver_selector"
require "sysinfo"
require "./system_monitor_components/system_monitor_app"

# sysinfo-сэмплер порта метрик (backend.cr остаётся dep-free — спеки
# подменяют детерминированным фейком). Скорости сети sysinfo отдаёт в
# KB/s; граф и human_rate работают в B/s.
SysMonRepo.sampler = -> : SysMon::Sample? do
  sample = SysMon::Sample.new
  Sysinfo.refresh_cpu
  sample.cores = Sysinfo.cpu_percentages.map(&.to_f64)
  if mem = Sysinfo.memory
    sample.ram_used_kb = mem.used_kb
    sample.ram_total_kb = mem.total_kb
  end
  Sysinfo.refresh_network
  if net = Sysinfo.network
    sample.rx_b_s = net.received_kb_s.to_f64 * 1024.0
    sample.tx_b_s = net.sent_kb_s.to_f64 * 1024.0
  end
  sample
end

# Headless drivers (debug scripts) set EGUI_NOWINDOW=1 before
# requiring this file to reuse the app class without opening a sokol
# window.
unless ENV["EGUI_NOWINDOW"]?
  Egui.run(SystemMonitorApp.new,
    title: "egui-cr — system monitor",
    inspector: :hidden)
end
