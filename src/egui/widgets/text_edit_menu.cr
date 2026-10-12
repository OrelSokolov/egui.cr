# Shared clipboard context menu for the text-editing widgets (TextEdit,
# Textarea): a long-press (touch — Memory synthesizes the secondary
# press) or a secondary press (mouse right-click) over the field opens
# Copy / Cut / Paste / Select All, each enabled per the current state.
#
# The item handlers run while the popup renders — AFTER the widget's
# #ui finished for that frame — so they only record a command under the
# widget's id (`CMD_SALT`); the widget's NEXT frame applies it before
# its keyboard pass and the new buffer flows out through the normal
# changed/widget_text pipeline.
#
# The clipboard probe for the Paste enable flag is cached per menu
# opening: on Android a clipboard read hops to the UI thread (see
# system_ports/android.cr) — not a per-frame cost while the menu sits
# open. The actual paste re-reads the clipboard at apply time.

module Egui
  module TextEditMenu
    CMD_SALT  = 0xC0DE_u64
    CLIP_SALT = 0xC1ED_u64

    # Attach the menu to `response`; call every frame from the widget's
    # #ui. `text`, `cursor`, `anchor` are this frame's edit state — the
    # enable flags read from them.
    def self.show(ui : Ui, id : Id, response : Response,
                  text : String, cursor : Int32, anchor : Int32) : Nil
      ctx = ui.ctx
      cmd_id = id.child(CMD_SALT)
      ctx.memory.use_id(cmd_id)

      menu_id = "context_menu_#{id.value}"
      clip_cell = id.child(CLIP_SALT)
      # Popup closed → drop the probe cache so the next opening
      # re-checks the clipboard.
      ctx.memory.data.set_string(clip_cell, "") unless ctx.popup_open?(menu_id)

      response.context_menu do |menu|
        has_sel = anchor >= 0 && anchor != cursor
        probe = ctx.memory.data.get_string(clip_cell, "")
        if probe.empty?
          has = !Egui::SystemPorts::Clipboard.text.to_s.empty?
          probe = has ? "1" : "0"
          ctx.memory.data.set_string(clip_cell, probe)
        end
        can_paste = probe == "1"

        menu.enabled(has_sel) do |m|
          m.menu_item("Copy", nil, :copy, "Ctrl+C") do
            ctx.memory.data.set_string(cmd_id, "copy")
          end
          m.menu_item("Cut", nil, nil, "Ctrl+X") do
            ctx.memory.data.set_string(cmd_id, "cut")
          end
        end
        menu.enabled(can_paste) do |m|
          m.menu_item("Paste", nil, :paste, "Ctrl+V") do
            ctx.memory.data.set_string(cmd_id, "paste")
          end
        end
        menu.enabled(!text.empty?) do |m|
          m.menu_item("Select all", nil, nil, "Ctrl+A") do
            ctx.memory.data.set_string(cmd_id, "select_all")
          end
        end
      end
    end

    # Apply a recorded menu command; the widgets call this BEFORE their
    # keyboard pass. Returns {text, cursor, anchor, changed} with the
    # command cell cleared. `single_line` pastes with line breaks
    # stripped (upstream single-line behavior).
    def self.apply(ctx : Context, id : Id, text : String, cursor : Int32,
                   anchor : Int32, single_line : Bool)
      cmd_id = id.child(CMD_SALT)
      cmd = ctx.memory.data.get_string(cmd_id, "")
      return {text, cursor, anchor, false} if cmd.empty?
      ctx.memory.data.set_string(cmd_id, "")

      has_sel = anchor >= 0 && anchor != cursor
      sel_min = {cursor, anchor}.min
      sel_max = {cursor, anchor}.max
      case cmd
      when "copy"
        Egui::SystemPorts::Clipboard.text = text[sel_min...sel_max] if has_sel
      when "cut"
        if has_sel
          Egui::SystemPorts::Clipboard.text = text[sel_min...sel_max]
          return {text[0...sel_min] + text[sel_max..], sel_min, sel_min, true}
        end
      when "paste"
        if (paste = Egui::SystemPorts::Clipboard.text)
          paste = paste.gsub(/\r\n|\r|\n/, " ") if single_line
          at = has_sel ? sel_min : cursor
          tail = has_sel ? text[sel_max..] : text[cursor..]
          return {text[0...at] + paste + tail, at + paste.size,
                  at + paste.size, true}
        end
      when "select_all"
        return {text, text.size, 0, false}
      end
      {text, cursor, anchor, false}
    end
  end
end
