# LineIndex — the search1m data model: the text as ONE flat byte
# buffer plus the line-start table (a String per line would pay ~2×
# the memory — a header per line); every row is a byte_slice away.
#
# Two constructors cover both worlds: .generate builds the synthetic
# benchmark corpus, .from_string indexes an arbitrary text (a loaded
# log file) — both share the scan.
#
# The scan is a monotonic bounded-memmem walk that never rescans, so
# the whole corpus is one O(bytes) pass — and #scan_range works over
# ANY line window, which is exactly what the parallel map needs: the
# corpus is cut into contiguous line ranges, each range maps to its
# Array(Int32) of matched line numbers, and the chunks concatenate in
# order.
#
# Shared by examples/search1m.cr (+ SearchCorpus below),
# examples/logs_viewer* and bench/search1m_bench.cr.

class LineIndex
  getter buf : String
  getter offs : Array(Int32)
  getter total : Int32

  # Caller owns the invariants: buf ends with '\n', offs is the
  # strictly-growing line-start table with offs.size == total + 1.
  def initialize(@buf : String, @offs : Array(Int32), @total : Int32)
  end

  # The synthetic corpus: `total` lines of "hello, this is line #N
  # from <unit> text file"; the unit word is "1 million"/"10 million"
  # for round millions, else the plain count.
  def self.generate(total : Int32, unit : String? = nil) : self
    unit ||= total >= 1_000_000 && (total % 1_000_000).zero? ?
             "#{total // 1_000_000} million" : total.to_s
    offs = Array(Int32).new(total + 2)
    offs << 0
    buf = String.build(total * 56) do |io|
      total.times do |i|
        io << "hello, this is line #" << (i + 1) << " from " << unit << " text file\n"
        offs << io.bytesize
      end
    end
    new(buf, offs, offs.size - 1)
  end

  # Index an existing text: splits on \n. A missing trailing newline
  # is appended — every line's \n must be IN the buffer, scan_range's
  # `lend = offs[i+1] - 1` arithmetic depends on it.
  def self.from_string(text : String) : self
    buf = text.ends_with?('\n') ? text : text + '\n'
    offs = [0]
    ptr = buf.to_unsafe
    n = buf.bytesize
    pos = 0
    while pos < n
      hit = LibC.memchr(ptr + pos, 10_u8, (n - pos).to_u64)
      break unless hit
      pos = (hit.as(Pointer(UInt8)) - ptr).to_i32 + 1
      offs << pos
    end
    new(buf, offs, offs.size - 1)
  end

  # One line's bytes (no \n) — only the visible band ever calls this.
  def line(idx : Int32) : String
    s = @offs.unsafe_fetch(idx)
    e = @offs.unsafe_fetch(idx + 1)
    @buf.byte_slice(s, e - s - 1)
  end

  def scan(query : String) : Array(Int32)
    scan_range(query, 0, @total)
  end

  # Every line in [c0, c1) containing `query` (byte-exact substring).
  #
  # `cand` is the byte position of the first possible occurrence
  # at-or-after the current point; #bounded_index advances it
  # monotonically (occurrences before it don't exist), so the scan is
  # O(bytes) over the range with no per-line rescans — a rare needle
  # costs one long hop, not one per line. It starts at -1: 0 would be
  # a real occurrence position. A query containing \n never matches
  # (single-line input can't produce one anyway).
  def scan_range(query : String, c0 : Int32, c1 : Int32) : Array(Int32)
    buf = @buf
    offs = @offs
    # First byte OUTSIDE this range: every hop is BOUNDED here —
    # String#byte_index scans to the buffer's end no matter what, so
    # a worker whose needle is absent would read the whole tail (22
    # workers × ~25 MB of redundant traffic — the slowdown the
    # benchmark caught).
    limit = offs.unsafe_fetch(c1)
    results = [] of Int32
    c = c0
    cand = -1
    while c < c1
      lstart = offs.unsafe_fetch(c)
      lend = offs.unsafe_fetch(c + 1) - 1 # drop the \n
      if cand < lstart
        cand = bounded_index(buf, query, lstart, limit) || limit
      end
      if cand < lend # cand >= lstart here → an in-line match
        results << c
        cand = bounded_index(buf, query, cand + 1, limit) || limit
      end
      c += 1
    end
    results
  end

  # First occurrence of `needle` in buf[from, limit), nil if none —
  # a bounded memmem: SIMD memchr for the first byte, memcmp to
  # verify. (Crystal's String#byte_index has no upper bound, and
  # String#index takes a CHAR offset it converts by rescanning from
  # the string's start — O(offset) per call, quadratic overall; see
  # scan_range.)
  def bounded_index(buf : String, needle : String,
                    from : Int32, limit : Int32) : Int32?
    n = needle.bytesize
    return from if n.zero?
    hay = buf.to_unsafe
    nd = needle.to_unsafe
    last = limit - n # last valid start position
    return nil if last < from
    first = nd[0]
    pos = from
    while pos <= last
      hit = LibC.memchr(hay + pos, first, (last - pos + 1).to_u64)
      return nil unless hit
      pos = (hit.as(Pointer(UInt8)) - hay).to_i32
      return pos if LibC.memcmp(hay + pos, nd, n.to_u64) == 0
      pos += 1
    end
    nil
  end

  # Balanced contiguous line ranges covering [0, total) — the chunks
  # of the parallel map (in order, so the per-chunk results
  # concatenate into a globally sorted line-number list).
  def chunks(workers : Int32) : Array(Tuple(Int32, Int32))
    return [{0, @total}] if workers <= 1 || @total.zero?
    step = (@total + workers - 1) // workers
    Array(Tuple(Int32, Int32)).new((@total + step - 1) // step) do |k|
      c0 = k * step
      {c0, {c0 + step, @total}.min}
    end
  end
end

# The search1m app's synthetic corpus — a LineIndex over the
# generated lines (kept as its own class so bench/search1m_bench.cr
# and the app read the same shape they were written against).
class SearchCorpus < LineIndex
  def initialize(total : Int32, unit : String? = nil)
    ix = LineIndex.generate(total, unit)
    super(ix.buf, ix.offs, ix.total)
  end
end
