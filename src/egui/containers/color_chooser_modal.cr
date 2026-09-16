# egui.cr-native (no upstream counterpart): GTK `GtkColorChooserDialog`
# pattern — the phase-6 ColorPicker embedded in a WindowModal, plus the
# dialog furniture GTK adds around it:
#
#   - an old/new swatch preview column on the picker's right;
#   - a hex entry (`#rrggbb`) synced both ways with the picker;
#   - a default palette of clickable swatches;
#   - Select closes, Cancel reverts to the color the dialog was
#     opened with (GTK keeps notifying live — `notify::rgba` — and
#     apps read the final value on response; the revert keeps the
#     live block-form helper honest).
#
#   Egui::ColorChooserModal.new("fg", @color) { |c| @color = c }.show(ctx)

module Egui
  class ColorChooserModal < WindowModal
    HEX_FIELD  = 0x210_u64
    OLD_COLOR  = 0x211_u64
    SIDE       = 0x212_u64
    BTN_SELECT = 0x220_u64
    BTN_CANCEL = 0x221_u64
    PALETTE    = 0x230_u64 # + swatch index

    # The palette swatch size and the side column width.
    SWATCH = Vec2.new(24.0, 18.0)
    SIDE_W = 120.0

    def initialize(id : String, @color : Color32,
                   title : String = "Select a Color",
                   width : Float64 = 460.0,
                   &@on_change : Color32 ->)
      super(id, title, width)
    end

    # Seed the hex field and remember the color to revert to.
    def on_open(ctx : Context) : Nil
      mem = ctx.memory
      mem.data.set_string(modal_id.child(HEX_FIELD), ColorChooserModal.hex(@color))
      mem.data.set_string(modal_id.child(OLD_COLOR), ColorChooserModal.hex(@color))
    end

    def body(ctx : Context, ui : Ui) : Nil
      mem = ctx.memory
      mid = modal_id
      hex_id = mid.child(HEX_FIELD)
      old_id = mid.child(OLD_COLOR)
      mem.use_id(hex_id)
      mem.use_id(old_id)
      old = ColorChooserModal.parse_hex(
        mem.data.get_string(old_id)) || @color

      top = ui.cursor
      resp = ui.add(ColorPicker.new(@color))
      if resp.changed? && (picked = resp.widget_color)
        set_color(ctx, picked)
      end

      # Side column at the picker's right (manual placement — the
      # picker advances a vertical Ui's cursor itself).
      side = ui.child_ui(Rect.from_min_size(
        Pos2.new(resp.rect.right + ui.style.spacing.item_spacing.x * 2.0, top.y),
        Vec2.new(SIDE_W, 1e6)), id: mid.child(SIDE))
      side.label("Old:")
      swatch(side, old)
      side.label("New:")
      swatch(side, @color)
      side.label("Hex (#rrggbb):")
      buf = mem.data.get_string(hex_id, ColorChooserModal.hex(@color))
      side.text_edit_singleline(buf) do |text|
        mem.data.set_string(hex_id, text)
        if (c = ColorChooserModal.parse_hex(text))
          @color = c
          @on_change.try(&.call(c))
        end
      end
      ui.min_rect = ui.min_rect.union(side.min_rect)

      # Default palette (GTK's chooser palette): rows of swatches,
      # ids keyed by the color's index (stable across rewraps).
      ui.separator
      ui.label("Palette:")
      per_row = {(ui.available_width / (SWATCH.x +
        ui.style.spacing.item_spacing.x)).floor.to_i, 1}.max
      PALETTE_COLORS.each_with_index.each_slice(per_row) do |chunk|
        ui.horizontal do |row|
          chunk.each do |color, i|
            swatch(row, color, id: mid.child(PALETTE + i.to_u64))
          end
        end
      end
    end

    def buttons(ctx : Context, ui : Ui) : Nil
      clicks = button_row(ui, [
        {modal_id.child(BTN_CANCEL), "Cancel"},
        {modal_id.child(BTN_SELECT), "Select"},
      ])
      if clicks[0] # Cancel: revert to the color at open time.
        old = ColorChooserModal.parse_hex(
          ctx.memory.data.get_string(modal_id.child(OLD_COLOR)))
        if (c = old) && c != @color
          @on_change.try(&.call(c))
        end
        close(ctx)
      end
      close(ctx) if clicks[1]
    end

    private def set_color(ctx : Context, color : Color32) : Nil
      @color = color
      @on_change.try(&.call(color))
      ctx.memory.data.set_string(modal_id.child(HEX_FIELD),
        ColorChooserModal.hex(color))
    end

    # A painted color swatch; with an `id` it is also a click target.
    # Allocated through the Ui so it lays out in either direction
    # (stacked in the side column, in a row in the palette).
    private def swatch(ui : Ui, color : Color32, id : Id? = nil) : Nil
      rect = ui.allocate_space(SWATCH)
      if id && ui.interact(rect, id, Sense.click).clicked?
        set_color(ui.ctx, color)
      end
      ui.painter.rect(rect, 3.0, color,
        ui.style.visuals.border_color, 1.0)
    end

    # GTK's default chooser palette (19 swatches).
    PALETTE_COLORS = [
      Color32.rgb(0, 0, 0), Color32.rgb(51, 51, 51),
      Color32.rgb(85, 85, 85), Color32.rgb(119, 119, 119),
      Color32.rgb(153, 153, 153), Color32.rgb(204, 204, 204),
      Color32.rgb(255, 255, 255),
      Color32.rgb(153, 0, 0), Color32.rgb(204, 0, 0),
      Color32.rgb(255, 0, 0), Color32.rgb(255, 102, 0),
      Color32.rgb(255, 153, 0), Color32.rgb(255, 204, 0),
      Color32.rgb(255, 255, 0), Color32.rgb(153, 255, 0),
      Color32.rgb(51, 204, 51), Color32.rgb(0, 153, 0),
      Color32.rgb(0, 102, 153), Color32.rgb(0, 0, 255),
    ] of Color32

    def self.hex(color : Color32) : String
      "#%02X%02X%02X" % {color.r, color.g, color.b}
    end

    # Parse `#rrggbb` (the `#` is optional, case-insensitive); nil
    # while the entry is not a full color yet.
    def self.parse_hex(text : String) : Color32?
      t = text.lchop('#').strip
      return nil unless t.size == 6
      r = t[0, 2].to_i?(16)
      g = t[2, 2].to_i?(16)
      b = t[4, 2].to_i?(16)
      return nil if r.nil? || g.nil? || b.nil?
      Color32.rgb(r, g, b)
    end
  end
end
