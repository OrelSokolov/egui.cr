# LogStore — a log file in the search1m shape: a LineIndex over the
# whole text plus a per-line level id (0 = no level tag found).
# Level classification runs ONCE per load (earliest level word in the
# line wins, so "ERROR: failed to parse INFO" is ERROR); after that
# the filter job only checks precomputed ids — level toggles never
# re-scan text.
#
# .from_text also drives the load progress block so the app can pump
# frames (and paint a progress line) while indexing a huge file.

require "../search1m_components/corpus"

class LogStore
  getter index : LineIndex
  getter line_levels : Array(UInt8)
  getter counts : Array(Int32) # [0] = unclassified, then per level
  getter path : String?        # nil = the synthetic demo log

  def initialize(@index : LineIndex, @line_levels : Array(UInt8),
                 @counts : Array(Int32), @path : String?)
  end

  def total : Int32
    @index.total
  end

  def line(i : Int32) : String
    @index.line(i)
  end

  def level_of(i : Int32) : Int32
    @line_levels.unsafe_fetch(i).to_i32
  end

  # Classify every line: the EARLIEST occurring level name wins. The
  # block fires every 64k lines (progress + a cooperative yield).
  def self.from_text(text : String, level_names : Array(String),
                     path : String?, &progress : Int32, Int32 -> Nil) : self
    index = LineIndex.from_string(text)
    buf = index.buf
    offs = index.offs
    nl = level_names.size
    levels = Array(UInt8).new(index.total, 0_u8)
    counts = Array(Int32).new(nl + 1, 0)
    i = 0
    while i < index.total
      lstart = offs.unsafe_fetch(i)
      lend = offs.unsafe_fetch(i + 1) - 1
      best = 0
      best_pos = Int32::MAX
      li = 0
      while li < nl
        if (pos = index.bounded_index(buf, level_names.unsafe_fetch(li),
                                      lstart, lend)) && pos < best_pos
          best = li + 1
          best_pos = pos
        end
        li += 1
      end
      levels.unsafe_put(i, best.to_u8!)
      counts[best] += 1
      if (i & 0xFFFF) == 0
        progress.call(i + 1, index.total)
      end
      i += 1
    end
    new(index, levels, counts, path)
  end

  # The demo log: timestamped lines with a deterministic level mix
  # (60% INFO / 25% DEBUG / 10% WARNING / 5% ERROR for the standard
  # four; unknown level names get an equal share) and three rotating
  # messages carrying the search1m payload — text filters have
  # something to chew on before any file is opened.
  DEMO_MIX = {"INFO" => 12, "DEBUG" => 5, "WARNING" => 2, "ERROR" => 1}
  MESSAGES = {
    "hello, this is line #%d from 1 million text file",
    "worker-%d picked up a job from the queue",
    "request #%d completed in 12.3ms",
  }
  # Padding without per-line allocations: 1M timestamp formats would
  # otherwise allocate ~7 strings per line just to write "09".
  PAD2 = (0..99).map { |v| v.to_s.rjust(2, '0') }
  PAD3 = (0..999).map { |v| v.to_s.rjust(3, '0') }

  def self.generate_demo(level_names : Array(String), total : Int32) : self
    mix = level_names.map { |n| DEMO_MIX[n]? || 1 }
    span = mix.sum
    levels = Array(UInt8).new(total, 0_u8)
    counts = Array(Int32).new(level_names.size + 1, 0)
    offs = Array(Int32).new(total + 2)
    offs << 0
    day_ms = 9 * 3_600_000 # 09:00:00.000
    buf = String.build(total * 64) do |io|
      total.times do |i|
        # pick the level: i % span lands in one of the weighted bins
        acc = i % span
        li = 0
        while acc >= mix.unsafe_fetch(li)
          acc -= mix.unsafe_fetch(li)
          li += 1
        end
        levels.unsafe_put(i, (li + 1).to_u8!)
        counts[li + 1] += 1
        ms = day_ms + i * 37
        io << PAD2.unsafe_fetch(ms // 3_600_000) << ':'
        io << PAD2.unsafe_fetch(ms // 60_000 % 60) << ':'
        io << PAD2.unsafe_fetch(ms // 1000 % 60) << '.'
        io << PAD3.unsafe_fetch(ms % 1000) << ' '
        io << level_names.unsafe_fetch(li) << "  "
        io << (MESSAGES.unsafe_fetch(i % 3) % (i + 1)) << '\n'
        offs << io.bytesize
      end
    end
    new(LineIndex.new(buf, offs, total), levels, counts, nil)
  end
end
