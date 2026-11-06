require "../../src/egui"
require "../paint/png"

# ═══ BACKEND ПРИЛОЖЕНИЯ (paint) ════════════════════════════════════
# MVC-разрез (plans/frontend-backend-split.md фаза 4; анализ —
# plans/mvc-examples-analysis.md §paint): ДОКУМЕНТ-слой — модель
# `Artwork` (пиксели, размер, path, dirty) с историей undo/redo КАК
# МЕТОДОМ МОДЕЛИ, контроллер `ArtworksController`
# (new/open/save/undo/redo), PNG-кодеки — ТЯЖЁЛЫЕ ДЕЙСТВИЯ-джобы §6.1
# (файл-IO не в кадре). Штрихи и жесты — эфемерное состояние вида
# (§обсуждение App API): высокочастотные правки НЕ ходят запросом —
# вид коммитит пиксели в модель напрямую (по ссылке, как TermView
# кормит PTY-сессию), после каждого грязного кадра.
#
# Конвенция пикселей: модель — единственный владелец канонических
# байтов; буфер НИКОГДА не мутируется на месте (replace! копирует),
# поэтому ссылки (undo-снапшоты, сэмпл джобы) безопасны. Вид узнаёт
# о внешних правках (undo, open) по pixels_version в срезе
# "artwork/meta" и пересинхронизирует канвас-виджет.
#
# Срезы стора: "artwork/meta" {path, dirty, width, height, can_undo,
# can_redo, pixels_version}, "paint/status" {text}. Файл driver-free.

# Размер по умолчанию нового документа (дубликат PaintXp::DEFAULT_* —
# модуль вида требует этот файл, а не наоборот).
PAINT_DEFAULT_W = 640
PAINT_DEFAULT_H = 480

# Undo-запись: канвас несёт свой размер (Open/Attributes ресайзят).
record PaintSnap, w : Int32, h : Int32, data : Bytes

class Artwork
  HISTORY_CAP = 25

  getter width : Int32
  getter height : Int32
  getter path : String?
  getter pixels : Bytes
  getter? dirty : Bool = false
  # Растёт на каждую замену пикселей (коммит, undo/redo, open, new) —
  # вид сверкивает одну цифру и тянет байты только при изменении.
  getter pixels_version : UInt64 = 0_u64

  def initialize(@width : Int32 = PAINT_DEFAULT_W, @height : Int32 = PAINT_DEFAULT_H)
    @pixels = blank(@width, @height)
    @undo_stack = [] of PaintSnap
    @redo_stack = [] of PaintSnap
  end

  def can_undo? : Bool
    !@undo_stack.empty?
  end

  def can_redo? : Bool
    !@redo_stack.empty?
  end

  # Зафиксировать точку отката ДО правки: снапшот текущих пикселей.
  # Ровно семантика домиграционного push_undo (жест вызывает на
  # старте, пиксели приедут коммитом позже).
  def push_undo! : Nil
    @undo_stack << PaintSnap.new(@width, @height, @pixels)
    @undo_stack.shift if @undo_stack.size > HISTORY_CAP
    @redo_stack.clear
    @dirty = true
  end

  # Отменить: текущее — в redo, вернуть и ПРИМЕНИТЬ снапшот.
  def undo! : PaintSnap?
    return nil if @undo_stack.empty?
    @redo_stack << PaintSnap.new(@width, @height, @pixels)
    snap = @undo_stack.pop
    restore(snap)
    snap
  end

  def redo! : PaintSnap?
    return nil if @redo_stack.empty?
    @undo_stack << PaintSnap.new(@width, @height, @pixels)
    snap = @redo_stack.pop
    restore(snap)
    snap
  end

  # Отменяющий снапшот не понадобился (текстовая сессия отменена до
  # коммита) — выбросить последнюю точку отката.
  def drop_last_undo! : Nil
    @undo_stack.pop
  end

  def clear_history! : Nil
    @undo_stack.clear
    @redo_stack.clear
  end

  # Коммит пикселей от вида (после грязного кадра): копия входного
  # буфера — канвас-виджет продолжит писать в свой. Совпадение —
  # no-op (view resync ↔ commit не пингует себя).
  def replace_pixels!(w : Int32, h : Int32, pixels : Bytes) : Nil
    return if w == @width && h == @height && pixels == @pixels
    @width = w
    @height = h
    @pixels = pixels.dup
    @pixels_version += 1
    @dirty = true
  end

  # Применить снапшот (undo/redo путь).
  def restore(snap : PaintSnap) : Nil
    @width = snap.w
    @height = snap.h
    @pixels = snap.data.dup
    @pixels_version += 1
  end

  # Загруженный файл: пиксели + сброс истории + clean.
  def apply_opened!(w : Int32, h : Int32, pixels : Bytes, path : String) : Nil
    @width = w
    @height = h
    @pixels = pixels.dup
    @pixels_version += 1
    @path = path
    @dirty = false
    clear_history!
  end

  # Новый документ: чистый лист, без истории и пути.
  def apply_new!(w : Int32 = PAINT_DEFAULT_W, h : Int32 = PAINT_DEFAULT_H) : Nil
    @width = w
    @height = h
    @pixels = blank(w, h)
    @pixels_version += 1
    @path = nil
    @dirty = false
    clear_history!
  end

  def saved!(path : String) : Nil
    @path = path
    @dirty = false
  end

  private def blank(w : Int32, h : Int32) : Bytes
    Bytes.new(w.to_i64 * h * 4, 255_u8) # белый
  end
end

class PaintRepo
  @@artwork = Artwork.new

  def self.artwork : Artwork
    @@artwork
  end

  def self.wire : Nil
    Egui::Mvc.state.on("artwork/meta") do |payload, w|
      w.set("artwork/meta", payload)
    end
    Egui::Mvc.state.on("paint/status") do |payload, w|
      w.set("paint/status", payload)
    end
  end

  def self.boot! : Nil
    wire
    sync!
  end

  # Проекция меты документа (пиксели — по ссылке через artwork, не в
  # JSON; pixels_version — сигнал вида пересинхронизироваться).
  def self.sync! : Nil
    a = @@artwork
    Egui::Mvc.state.dispatch("artwork/meta", Egui::Mvc.to_json_any({
      "path"            => a.path,
      "dirty"           => a.dirty?,
      "width"           => a.width,
      "height"          => a.height,
      "can_undo"        => a.can_undo?,
      "can_redo"        => a.can_redo?,
      "pixels_version"  => a.pixels_version,
    }))
  end

  def self.status!(text : String) : Nil
    Egui::Mvc.state.dispatch("paint/status",
      Egui::Mvc.to_json_any({"text" => text}))
  end

  # Коммит вида (грязный кадр отрисован): memcmp внутри no-op при
  # совпадении.
  def self.commit!(w : Int32, h : Int32, pixels : Bytes) : Nil
    before = @@artwork.pixels_version
    @@artwork.replace_pixels!(w, h, pixels)
    sync! if @@artwork.pixels_version != before
  end

  def self.reset! : Nil
    @@artwork.apply_new!
    sync!
    status!("New image (#{@@artwork.width}×#{@@artwork.height})")
  end

  def self.opened!(w : Int32, h : Int32, pixels : Bytes, path : String) : Nil
    @@artwork.apply_opened!(w, h, pixels, path)
    sync!
  end

  def self.saved!(path : String) : Nil
    @@artwork.saved!(path)
    sync!
  end
end

# --- Джобы (тяжёлый IO §6.1) ---------------------------------------------------

class PaintDecodeJob < Egui::Mvc::AsyncJob
  def initialize(@path : String)
    super()
  end

  def perform : Egui::Mvc::StateValue?
    img = PaintPng.decode_file(@path)
    PaintRepo.opened!(img.width, img.height, img.rgba, @path)
    PaintRepo.status!("Opened: #{@path}")
    Egui::Mvc.to_json_any({"width" => img.width, "height" => img.height})
  rescue ex : PaintPng::PngError
    # Статус — в срез (покажет статусбар), джоба честно фейлится.
    PaintRepo.status!("Cannot open: #{ex.message}")
    raise ex
  end
end

class PaintEncodeJob < Egui::Mvc::AsyncJob
  def initialize(@path : String, @pixels : Bytes, @w : Int32, @h : Int32)
    super()
  end

  def perform : Egui::Mvc::StateValue?
    path = @path.ends_with?(".png") ? @path : "#{@path}.png"
    File.write(path, PaintPng.encode(@pixels, @w, @h))
    PaintRepo.saved!(path)
    PaintRepo.status!("Saved: #{path}")
    Egui::Mvc.to_json_any({"path" => path})
  rescue ex : IO::Error | File::Error
    PaintRepo.status!("Cannot save: #{ex.message}")
    raise ex
  end
end

# --- Контроллер ----------------------------------------------------------------

class ArtworksController < Egui::Mvc::Controller
  # POST /artwork/new — чистый лист 640×480, история сброшена.
  def create(request)
    PaintRepo.reset!
    {"ok" => true}
  end

  # POST /artwork/open {path} — decode-джоба; результат приедет
  # срезами (мета + статус), не ответом (202).
  def open(request)
    path = request.body["path"]?.try(&.as_s?)
    return Egui::Mvc::Response.new(422,
      Egui::Mvc.to_json_any({"error" => "path required"})) unless path

    PaintDecodeJob.new(path).perform_later
    Egui::Mvc::Response.new(202,
      Egui::Mvc.to_json_any({"ok" => true}))
  end

  # POST /artwork/save {path?} — encode-джоба; без path сохраняет в
  # путь документа, а если и его нет — 409 (вид зовёт Save As).
  def save(request)
    path = request.body["path"]?.try(&.as_s?) || PaintRepo.artwork.path
    return Egui::Mvc::Response.new(409,
      Egui::Mvc.to_json_any({"error" => "no path"})) unless path

    art = PaintRepo.artwork
    PaintEncodeJob.new(path, art.pixels, art.width, art.height).perform_later
    Egui::Mvc::Response.new(202,
      Egui::Mvc.to_json_any({"ok" => true}))
  end

  # POST /artwork/undo | /redo — история как метод модели; пиксели
  # едут в вид по ссылке через pixels_version.
  def undo(request)
    PaintRepo.artwork.undo!
    PaintRepo.sync!
    {"ok" => true}
  end

  def redo(request)
    PaintRepo.artwork.redo!
    PaintRepo.sync!
    {"ok" => true}
  end

  actions
end

PAINT_ROUTES = Egui::Mvc::Router.new.draw do |r|
  r.post "/artwork/new", ArtworksController, "create"
  r.post "/artwork/open", ArtworksController, "open"
  r.post "/artwork/save", ArtworksController, "save"
  r.post "/artwork/undo", ArtworksController, "undo"
  r.post "/artwork/redo", ArtworksController, "redo"
end
