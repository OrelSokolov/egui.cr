# VT500-series parser: the Paul Williams DEC state machine (the same
# design as `vte`/alacritty) decoding a byte stream into print /
# execute / ESC / CSI / OSC callbacks on a `Terminal`.
#
# UTF-8 is decoded incrementally in the ground state. Charset
# selection (ESC ( 0) arrives as a normal esc_dispatch with the
# selector as the intermediate byte. DCS sequences are collected like
# CSI and their payload is consumed and discarded (sixel and tmux
# paste are out of scope); ':'-style SGR subparameters parse as plain
# parameters.

module Egui
  module Terminal
    class Parser
      private enum State
        Ground
        Escape
        EscapeInt
        Csi
        CsiInt
        Osc
        OscEsc
        Str      # DCS payload / SOS / PM / APC — consume till ST
        StrEsc
      end

      def initialize(@term : Terminal)
        @state = State::Ground
        @params = [] of Int32
        @cur = -1      # param being collected (-1 = unset)
        @priv = ""     # CSI private markers (?, >, <, =)
        @inters = ""   # intermediate bytes (0x20-0x2F)
        @osc_buf = IO::Memory.new
        @dcs = false   # collecting a DCS (params, then payload)
        @utf8_cp = 0u32
        @utf8_left = 0
      end

      def feed(bytes : Bytes) : Nil
        idx = 0
        size = bytes.size
        while idx < size
          step(bytes.unsafe_fetch(idx))
          idx += 1
        end
      end

      def feed(text : String) : Nil
        feed(text.to_slice)
      end

      private def step(b : UInt8) : Nil
        case @state
        in .ground?     then ground(b)
        in .escape?     then escape(b)
        in .escape_int? then escape_int(b)
        in .csi?        then csi(b)
        in .csi_int?    then csi_int(b)
        in .osc?        then osc(b)
        in .osc_esc?    then osc_esc(b)
        in .str?        then str(b)
        in .str_esc?    then str_esc(b)
        end
      end

      # --- states ------------------------------------------------------

      private def ground(b : UInt8) : Nil
        case b
        when 0x00..0x17, 0x19, 0x1C..0x1F then @term.execute(b)
        when 0x1B                          then @state = State::Escape
        when 0x18, 0x1A                    then @term.execute(b)
        when 0x20..0x7E                    then @term.print(b.to_u32)
        when 0x7F                           # DEL: ignore
        else                                    utf8(b)
        end
      end

      private def utf8(b : UInt8) : Nil
        if @utf8_left > 0
          if b & 0xC0 == 0x80
            @utf8_cp = (@utf8_cp << 6) | (b & 0x3F)
            @utf8_left -= 1
            if @utf8_left == 0
              cp = @utf8_cp
              # overlong encodings and surrogates are invalid
              cp = 0xFFFDu32 if cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)
              @term.print(cp)
            end
          else
            @utf8_left = 0
            @term.print(0xFFFDu32)
            utf8(b) # reprocess as a possible new lead byte
          end
          return
        end
        case b
        when 0xC2..0xDF then @utf8_cp = (b & 0x1F).to_u32; @utf8_left = 1
        when 0xE0..0xEF then @utf8_cp = (b & 0x0F).to_u32; @utf8_left = 2
        when 0xF0..0xF4 then @utf8_cp = (b & 0x07).to_u32; @utf8_left = 3
        else                 @term.print(0xFFFDu32) # stray continuation
        end
      end

      private def escape(b : UInt8) : Nil
        case b
        when 0x00..0x17, 0x19, 0x1C..0x1F then @term.execute(b)
        when 0x18, 0x1A, 0x1B             then @term.execute(b)
        when 0x20..0x2F                   then @inters = byte_char(b); @state = State::EscapeInt
        when 0x30..0x4F, 0x51..0x57, 0x59, 0x5A, 0x5C, 0x60..0x7E
          @term.esc_dispatch("", b); @state = State::Ground
        when 0x50 then reset_seq; @dcs = true; @state = State::Csi
        when 0x58, 0x5E, 0x5F then @state = State::Str # SOS/PM/APC
        when 0x5B then reset_seq; @state = State::Csi
        when 0x5D then @osc_buf.clear; @state = State::Osc
        when 0x7F # ignore
        end
      end

      private def escape_int(b : UInt8) : Nil
        case b
        when 0x00..0x17, 0x19, 0x1C..0x1F then @term.execute(b)
        when 0x20..0x2F                   then @inters += byte_char(b)
        when 0x30..0x7E                   then @term.esc_dispatch(@inters, b); @state = State::Ground
        when 0x7F                          # ignore
        end
      end

      private def csi(b : UInt8) : Nil
        case b
        when 0x00..0x17, 0x19, 0x1C..0x1F then @term.execute(b)
        when 0x30..0x39
            base = {@cur, 0}.max
            # clamp absurd parameters (e.g. fuzzed input) before Int32 overflows
            @cur = base > 100_000 ? base : base * 10 + (b - 0x30)
        when 0x3A, 0x3B                   then push_param
        when 0x3C..0x3F                   then @priv += byte_char(b)
        when 0x20..0x2F                   then @inters += byte_char(b); @state = State::CsiInt
        when 0x40..0x7E
          push_param if @cur >= 0 || !@params.empty?
          finish_csi(b)
        when 0x7F # ignore
        end
      end

      private def csi_int(b : UInt8) : Nil
        case b
        when 0x00..0x17, 0x19, 0x1C..0x1F then @term.execute(b)
        when 0x20..0x2F                   then @inters += byte_char(b)
        when 0x30..0x3E                   then @state = State::Csi # malformed; resync
        when 0x40..0x7E
          push_param if @cur >= 0 || !@params.empty?
          finish_csi(b)
        when 0x7F # ignore
        end
      end

      private def finish_csi(final : UInt8) : Nil
        @state = State::Ground
        if @dcs
          # DCS: params collected, payload follows — consume till ST.
          @dcs = false
          @state = State::Str
        else
          @term.csi_dispatch(@priv, @inters, @params, final)
        end
      end

      private def osc(b : UInt8) : Nil
        case b
        when 0x07    then osc_end
        when 0x1B    then @state = State::OscEsc
        when 0x18, 0x1A then @osc_buf.clear; @state = State::Ground
        when 0x00..0x06, 0x08..0x17, 0x19, 0x1C..0x1F # ignore
        else              @osc_buf.write_byte(b)
        end
      end

      # Byte after ESC inside an OSC string: '\' terminates (ST);
      # anything else aborts the string and starts a new sequence.
      private def osc_esc(b : UInt8) : Nil
        osc_end
        escape(b) if b != '\\'
      end

      private def str(b : UInt8) : Nil
        case b
        when 0x1B then @state = State::StrEsc
        when 0x07 then @state = State::Ground # BEL terminates (liberal)
        end
      end

      private def str_esc(b : UInt8) : Nil
        if b == 0x5C
          @state = State::Ground
        else
          @state = State::Ground
          escape(b)
        end
      end

      private def osc_end : Nil
        @term.osc_dispatch(@osc_buf.to_s)
        @osc_buf.clear
        @state = State::Ground
      end

      # --- helpers -----------------------------------------------------

      private def reset_seq : Nil
        @params.clear
        @cur = -1
        @priv = ""
        @inters = ""
      end

      private def push_param : Nil
        @params << @cur
        @cur = -1
      end

      private def byte_char(b : UInt8) : String
        b.chr.to_s
      end
    end
  end
end
