lib LibStb
  fun font_info_new = egui_cr_font_info_new(data : UInt8*, font_index : Int32) : Void*
  fun font_vmetrics = egui_cr_font_vmetrics(info : Void*, a : Int32*, d : Int32*, g : Int32*)
  fun font_find_glyph = egui_cr_font_find_glyph(info : Void*, unicode : Int32) : Int32
  fun glyph_hmetrics = egui_cr_glyph_hmetrics(info : Void*, glyph : Int32, adv : Int32*, lsb : Int32*)
  fun scale_for_pixel_height = egui_cr_scale_for_pixel_height(info : Void*, px : Float32) : Float32
  fun glyph_shape = egui_cr_glyph_shape(info : Void*, glyph : Int32, count : Int32*) : Void*
  fun glyph_shape_free = egui_cr_glyph_shape_free(info : Void*, vertices : Void*)
end

class Fonts
  getter info : Void*
  @asc = 0.0
  @desc = 0.0

  def initialize(@font_data : String)
    @info = LibStb.font_info_new(@font_data.to_unsafe, 0)
    raise "not loaded" if @info.null?
    asc = uninitialized Int32; desc = uninitialized Int32; gap = uninitialized Int32
    LibStb.font_vmetrics(@info, pointerof(asc), pointerof(desc), pointerof(gap))
    @asc = asc.to_f64; @desc = desc.to_f64
  end

  def test(word : String) : Nil
    word.each_char do |ch|
      gid = LibStb.font_find_glyph(@info, ch.ord)
      adv = uninitialized Int32; lsb = uninitialized Int32
      LibStb.glyph_hmetrics(@info, gid, pointerof(adv), pointerof(lsb))
      count = uninitialized Int32
      v = LibStb.glyph_shape(@info, gid, pointerof(count))
      puts "#{ch} gid=#{gid} adv=#{adv} count=#{count}"
      LibStb.glyph_shape_free(@info, v) unless v.null?
    end
  end
end

data = File.read("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
fonts = Fonts.new(data)
puts "loaded asc=#{fonts.@asc}"
fonts.test("File")
fonts.test("Edit View Widgets Layout")
puts "OK"
