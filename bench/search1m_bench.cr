# Headless benchmark of search1m's ring search — the corpus and the
# scan from examples/search1m_components/corpus.cr, no GUI. Measures
# the corpus build, the per-line naive baseline (a String#includes?
# per line), the sequential monotonic index scan, and — built with
# -Dexecution_context — the parallel chunk map over an
# ExecutionContext::Parallel pool (the pattern the app runs). Every
# leg is verified against the naive result.
#
#   crystal build --release bench/search1m_bench.cr -o bin/benchmarks/search1m_bench
#   crystal build --release -Dexecution_context bench/search1m_bench.cr -o bin/benchmarks/search1m_bench
#   ./bin/benchmarks/search1m_bench              # 1M lines
#   N=10000000 ./bin/benchmarks/search1m_bench   # the 10M leg
#
# The parallel leg only exists in a -Dexecution_context build; a
# plain build reports the sequential numbers (and says so).

require "../examples/search1m_components/corpus"

N = (ENV["N"]? || "1000000").to_i
RUNS = (ENV["RUNS"]? || "5").to_i # best-of (timing noise, not avg)

def fmt(n : Int) : String
  s = n.to_s
  String.build(s.size + s.size // 3) do |io|
    s.each_char_with_index do |ch, i|
      io << ch
      r = s.size - i - 1
      io << ' ' if r > 0 && r % 3 == 0
    end
  end
end

def best_ms(&) : Float64
  best = Float64::MAX
  RUNS.times do
    t0 = Time.instant
    yield
    best = {best, (Time.instant - t0).total_milliseconds}.min
  end
  best
end

# The naive baseline: a line slice + includes? per line (what the
# "just loop over the lines" version costs — the slices allocate).
def scan_naive(c : SearchCorpus, q : String) : Array(Int32)
  res = [] of Int32
  c.total.times { |i| res << i if c.line(i).includes?(q) }
  res
end

{% if flag?(:execution_context) %}
  # The app's parallel map, lifted verbatim: one line range per
  # worker on a Parallel pool, ordered merge of the per-chunk arrays.
  def scan_parallel(c : SearchCorpus, q : String,
                    pool : Fiber::ExecutionContext::Parallel,
                    workers : Int32) : Array(Int32)
    ranges = c.chunks(workers)
    ch = Channel(Tuple(Int32, Array(Int32))).new(ranges.size)
    ranges.each_with_index do |(c0, c1), k|
      pool.spawn do
        ch.send({k, c.scan_range(q, c0, c1)})
      end
    end
    slots = Array(Array(Int32)?).new(ranges.size, nil)
    ranges.size.times do
      k, batch = ch.receive
      slots[k] = batch
    end
    merged = Array(Int32).new(c.total // 4 + 16)
    slots.each { |b| merged.concat(b.not_nil!) }
    merged
  end
{% end %}

t0 = Time.instant
corpus = SearchCorpus.new(N)
build_ms = (Time.instant - t0).total_milliseconds
mb = corpus.buf.bytesize / 1_048_576.0

{% if flag?(:execution_context) %}
  workers = Fiber::ExecutionContext.default_workers_count
  pool = Fiber::ExecutionContext::Parallel.new("bench", workers)
  puts "search1m bench · #{fmt(corpus.total)} lines · #{mb.round(1)} MB · parallel ×#{workers} · best-of-#{RUNS}"
  puts "query                    matches      naive     sequential   parallel"
{% else %}
  puts "search1m bench · #{fmt(corpus.total)} lines · #{mb.round(1)} MB · no -Dexecution_context: sequential search only · best-of-#{RUNS}"
  puts "query                    matches      naive     sequential"
{% end %}
printf("corpus: %.0f ms (%.1f MB)\n\n", build_ms, mb)

# Every day, worst and best case: a match-everywhere needle, a rare
# one, a numeric prefix (many hits), and a no-hit one.
QUERIES = ["hello", "line #999999", "#1", "text file", "zzz-nope"]

QUERIES.each do |q|
  want = scan_naive(corpus, q)
  naive_ms = best_ms { scan_naive(corpus, q) }
  seq = corpus.scan(q)
  abort("BUG: seq != naive for #{q.inspect}") unless seq == want
  seq_ms = best_ms { corpus.scan(q) }
  {% if flag?(:execution_context) %}
    par = scan_parallel(corpus, q, pool, workers)
    abort("BUG: par != naive for #{q.inspect}") unless par == want
    par_ms = best_ms { scan_parallel(corpus, q, pool, workers) }
    printf("%-22s %12s %10.1fms %10.1fms %10.1fms  ×%.1f\n",
      q.inspect, fmt(want.size), naive_ms, seq_ms, par_ms, seq_ms / par_ms)
  {% else %}
    printf("%-22s %12s %10.1fms %10.1fms\n",
      q.inspect, fmt(want.size), naive_ms, seq_ms)
  {% end %}
end

seq_all = best_ms { corpus.scan("hello") }
printf("\nthroughput (query \"hello\", everything matches): %.0f MB/s sequential\n",
  mb / (seq_all / 1000.0))
{% if flag?(:execution_context) %}
  par_all = best_ms { scan_parallel(corpus, "hello", pool, workers) }
  printf("throughput (query \"hello\", everything matches): %.0f MB/s parallel (×%d)\n",
    mb / (par_all / 1000.0), workers)
{% end %}
