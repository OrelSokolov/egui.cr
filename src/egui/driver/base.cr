# Контракт драйвера (plans/frontend-backend-split.md §8): окно, цикл
# кадров, GPU, ввод. Реализации: egui — Driver::Sokol (handle ниже в
# driver/sokol.cr), positron — WebView-драйвер. Пять методов, один
# интерфейс, разные потроха; драйверы к одному коду не сводятся.
#
# Это бывший egui/runtime.cr — «полуфабрикат драйвера»: три глобальные
# переменные стали методами контракта, а локатор Driver::Base.current
# ставится драйвером при старте (nil в headless-тестах — все хуки
# безопасно no-op). Ядро (Context, Http, Mvc-транспорт) знает о
# драйвере ТОЛЬКО через этот контракт.

module Egui
  module Driver
    abstract class Base
      # Локатор: живой драйвер или nil (headless-спеки, библиотечное
      # использование без окна).
      class_property current : Base?

      # Войти в цикл. У sokol точка входа — Driver::Sokol.run (класс-
      # метод, его оборачивает Egui.run); контрактный #run существует,
      # чтобы владеть циклом единым интерфейсом.
      abstract def run : Nil

      # Покинуть цикл и закрыть окно.
      abstract def stop : Nil

      # «Нарисуй кадр» — дверной колокольчик для файберов, работающих
      # МЕЖДУ кадрами (ридеры PTY, async-диалоги, MVC-транспорт):
      # результат готов — произведи кадр, он его увидит.
      abstract def wake : Nil

      # «Я в фрейм-файбере?» — гарды, которым нельзя блокировать или
      # трогать состояние кадра изнутри update.
      abstract def gui_context? : Bool

      # Выполнить блок в потоке отрисовки (следующий кадр).
      abstract def run_on_main(& : ->) : Nil

      # True, когда цикл приложения владеет планировщиком Crystal
      # (detached-цикл рендера): файберы-читатели живут сами, и
      # per-frame костыли планировщика не нужны.
      def natural_scheduler? : Bool
        false
      end

      # То же через локатор (nil-безопасно) — удобнее читателям ядра.
      def self.natural_scheduler? : Bool
        current.try(&.natural_scheduler?) || false
      end

      # Legacy-костыль однопоточного цикла: один ограниченный проход
      # планировщика на кадр, чтобы файберы событийного IO (PTY-сессии)
      # двигались внутри блокирующего C-цикла sapp_run. Ставится
      # require-таймом нативного файла (driver/pty.cr), читается
      # on_frame перед begin_frame; под natural-планировщиком — no-op.
      class_property frame_scheduler_pass : Proc(Nil)? = nil
    end
  end
end
