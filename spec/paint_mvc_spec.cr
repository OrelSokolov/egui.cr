require "spec"
require "../examples/paint_components/artwork"

# paint MVC (фаза 4): документ-слой — модель Artwork (пиксели, история
# undo/redo, path, dirty) + ArtworksController (new/open/save/undo/
# redo) + PNG-кодеки как AsyncJob. Пиксели между слоями ходят ПО
# ССЫЛКЕ (Bytes), через State — только мета и статусы.

def paint_mvc_pump(limit = 50) : Nil
  limit.times do
    Egui::Mvc.pump_pass
    break unless Egui::Mvc.pending?
  end
end

def paint_mvc_call(method : String, path : String,
                   body : JSON::Any? = nil) : Egui::Mvc::Response
  got = [] of Egui::Mvc::Response
  req = body ? Egui::Mvc::Request.new(method, path, body: body.not_nil!) :
               Egui::Mvc::Request.new(method, path)
  Egui::Mvc.transport.call(req) { |r| got << r }
  paint_mvc_pump
  got.first.not_nil!
end

def paint_meta : JSON::Any?
  Egui::Mvc.state["artwork/meta"]?
end

def paint_wait(limit = 500, & : -> Bool) : Nil
  limit.times do
    sleep 1.millisecond
    break if yield
  end
end

describe "paint MVC" do
  before_each do
    PaintRepo.boot!
    Egui::Mvc.transport = Egui::Mvc::InProcessTransport.new(PAINT_ROUTES)
  end

  it "модель: undo/redo — методы Artwork, пиксели восстанавливаются" do
    art = PaintRepo.artwork
    art.apply_new!(4, 4)
    art.push_undo!
    px = art.pixels.dup
    px[0] = 9_u8
    art.replace_pixels!(4, 4, px)
    art.dirty?.should be_true

    art.undo!
    art.pixels[0].should eq 255_u8 # белый исходник
    art.can_redo?.should be_true

    art.redo!
    art.pixels[0].should eq 9_u8
  end

  it "модель: коммит тех же пикселей — no-op (версия не растёт)" do
    art = PaintRepo.artwork
    art.apply_new!(4, 4)
    v = art.pixels_version
    art.replace_pixels!(art.width, art.height, art.pixels.dup)
    art.pixels_version.should eq v
  end

  it "модель: drop_last_undo! и история очищается на new" do
    art = PaintRepo.artwork
    art.apply_new!(4, 4)
    art.push_undo!
    art.drop_last_undo!
    art.can_undo?.should be_false
    art.push_undo!
    PaintRepo.sync!
    paint_meta.not_nil!["can_undo"].as_bool.should be_true
  end

  it "new: чистый лист, путь/история сброшены" do
    art = PaintRepo.artwork
    art.push_undo! # делает dirty
    paint_mvc_call("POST", "/artwork/new").ok?.should be_true

    meta = paint_meta.not_nil!
    meta["dirty"].as_bool.should be_false
    meta["path"].raw.nil?.should be_true
    meta["can_undo"].as_bool.should be_false
    art.can_undo?.should be_false
  end

  it "undo/redo по роутам: флаги в срезе artwork/meta" do
    art = PaintRepo.artwork
    paint_mvc_call "POST", "/artwork/new"
    art.push_undo!
    px = art.pixels.dup
    px[0] = 7_u8
    art.replace_pixels!(art.width, art.height, px)
    PaintRepo.sync!
    paint_meta.not_nil!["can_undo"].as_bool.should be_true

    paint_mvc_call "POST", "/artwork/undo"
    meta = paint_meta.not_nil!
    meta["can_undo"].as_bool.should be_false
    meta["can_redo"].as_bool.should be_true
    PaintRepo.artwork.pixels[0].should eq 255_u8

    paint_mvc_call "POST", "/artwork/redo"
    meta = paint_meta.not_nil!
    meta["can_redo"].as_bool.should be_false
    meta["can_undo"].as_bool.should be_true
  end

  it "save без пути и без пути документа — 409" do
    paint_mvc_call "POST", "/artwork/new"
    paint_mvc_call("POST", "/artwork/save").status.should eq 409
  end

  it "open/save: PNG-джобы, мета и статус едут срезами" do
    # Кодек: 3×2 сплошной красный PNG.
    w, h = 3, 2
    red = Bytes.new(w * h * 4, 0_u8)
    (0...w * h).each { |i| red[i * 4] = 255_u8; red[i * 4 + 3] = 255_u8 }
    src = File.tempname("paint_mvc_src", ".png")
    File.write(src, PaintPng.encode(red, w, h))
    dst = File.tempname("paint_mvc_dst", ".png")

    begin
      resp = paint_mvc_call "POST", "/artwork/open",
        Egui::Mvc.to_json_any({"path" => src})
      resp.status.should eq 202
      paint_wait { (m = paint_meta) ? m["path"].as_s? == src : false }
      meta = paint_meta.not_nil!
      meta["width"].as_i.should eq w
      meta["height"].as_i.should eq h
      meta["dirty"].as_bool.should be_false
      PaintRepo.artwork.pixels[0].should eq 255_u8

      # Правка (коммит вида) → dirty → save-джоба
      art = PaintRepo.artwork
      art.push_undo!
      px = art.pixels.dup
      px[0] = 9_u8
      art.replace_pixels!(art.width, art.height, px)
      PaintRepo.sync!
      paint_meta.not_nil!["dirty"].as_bool.should be_true

      resp = paint_mvc_call "POST", "/artwork/save",
        Egui::Mvc.to_json_any({"path" => dst})
      resp.status.should eq 202
      paint_wait { File.exists?(dst) && paint_meta.not_nil!["dirty"].as_bool == false }

      img = PaintPng.decode_file(dst)
      img.rgba[0].should eq 9_u8
      paint_meta.not_nil!["dirty"].as_bool.should be_false
      status = Egui::Mvc.state["paint/status"].not_nil!
      status["text"].as_s.should start_with "Saved:"
    ensure
      File.delete?(src)
      File.delete?(dst)
    end
  end

  it "open битого пути: джоба фейлится, статус — в срезе" do
    resp = paint_mvc_call "POST", "/artwork/open",
      Egui::Mvc.to_json_any({"path" => "/no/such/file.png"})
    resp.status.should eq 202
    paint_wait do
      if (s = Egui::Mvc.state["paint/status"]?)
        !s["text"]?.try(&.as_s?).nil?
      else
        false
      end
    end
    Egui::Mvc.state["paint/status"].not_nil!["text"].as_s
      .should start_with "Cannot open:"
  end
end
