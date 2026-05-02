# Decide Between Sync.mutex And Sync.rwmutex For A Read-heavy In-memory Metadata Cache Design

**Goal:** [https://pkg.go.dev/sync#Map] `sync.Map` is not the default answer for this decision because the standard library describes it as specialized and says most code should use a plain map with separate lo

**Architecture:** ### The empirical surprise

**Tech Stack:**
- (see Components section)

---

## Architecture

**Recommendation: start with `sync.Mutex` for a metadata cache. Promote to `sync.RWMutex` ONLY if a benchmark of your actual workload shows reads doing real work (full map operations, range/scan APIs, ≥10× more reads than writes) and proves the win.** The folk wisdom "read-heavy = RWMutex" is necessary-but-not-sufficient; the lock primitive only matters when reads do enough work between `RLock`/`RUnlock` to amortize RWMutex's coordination overhead.

### The empirical surprise

Three benchmarks span the regime where the answer flips:

| Workload | Mutex | RWMutex (reads) | Verdict |
|---|---|---|---|
| **Trivial counter** (read = `n++`) | 10.81 ms | 10.48 ms | Tied — RWMutex's parallel-reader win is swamped by its per-RLock atomic + cache-coherence cost. |
| **Map lookup** (1k goroutines × 10k iters) | 2,137 ms | 456 ms | RWMutex wins ~4.7× — real work between RLock/RUnlock makes overlap valuable. |
| **Range/iteration** over shared map (10 concurrent) | 906 ms | 143 ms | RWMutex wins ~6× — long-held read locks; this is where RWMutex pays off most. |
| **Write-heavy** | 2,390 ms | 2,637 ms | Mutex wins — RWMutex protocol cost adds latency without parallelism benefit. |

For a "metadata cache" the answer depends on what shape your reads take:

- **Pure point lookup** (`get(key) → value`, single map access) → trivial-counter regime → Mutex wins or ties.
- **Lookup + decode + transform** (read holds the lock through a copy/serialize/scan) → map-lookup regime → RWMutex wins.
- **Iteration / "list all keys" / scan API** → range regime → RWMutex strongly wins.

### The RWMutex tax that the API name hides

`RWMutex` is structurally heavier than `Mutex`:

- 5 coordination fields (`w Mutex`, `writerSem`, `readerSem`, `readerCount atomic.Int32`, `readerWait atomic.Int32`) vs Mutex's 2-word state.
- Each `RLock()` issues `atomic.AddInt32(&readerCount, 1)`, invalidating the cache line containing `readerCount` across every core that previously read it. Per-RLock cost effectively scales O(GOMAXPROCS) under cache-coherence traffic.
- This is why "more readers = faster" intuition breaks at scale: the fast path itself becomes contended.

### The decision tree

1. **Will this cache see writes ≥ reads?** → `sync.Mutex`. RWMutex loses on both axes.
2. **Are reads single-instruction-feeling (one map lookup, one pointer load, return)?** → `sync.Mutex`. The RWMutex coordination tax exceeds the parallel-reader win.
3. **Do reads hold the lock through real work (decode, copy, range, transform, sub-µs+)?** AND **threads ≥ a few CPU cores?** AND **read:write ratio ≥ 10:1?** → benchmark **both** with your real workload; commit to whichever wins under load.
4. **Does the API include "list all" / iteration / scan?** → tilt strongly toward `RWMutex` for that path; the range benchmark shows ~6× win and metadata caches commonly have this.
5. **Special case**: if entries are write-once-then-read-forever (immutable after population), consider `sync.Map` (its first-listed optimized pattern). Otherwise `sync.Map`'s docs say "most code should use a plain Go map instead, with separate locking."

### What this is NOT

- This is NOT a recommendation to "always start small and optimize later." If you already know your workload is iteration-heavy, ship `RWMutex` from day one — the wins are large enough to justify the up-front choice.
- This is NOT a recommendation to use `sync.Map` reflexively for "concurrent maps." Its docs are explicit: it's specialized for two patterns (write-once-many-read, disjoint key sets across goroutines); outside those, plain map + Mutex/RWMutex is faster and clearer.
- This is NOT a recommendation to optimize the lock primitive in isolation. If contention is the real cost, sharding (per-key-hash buckets, each with its own Mutex) outperforms either single-Mutex or single-RWMutex by removing contention rather than tuning it. That's a different decision class.

### The cross-cutting non-negotiables

- **Both `Mutex` and `RWMutex` must NOT be copied after first use.** Pass cache structs by pointer, never by value.
- **`RWMutex` prohibits recursive read-locking and forbids RLock→Lock upgrade.** Don't design code paths that would want to escalate from read to write under the same goroutine.
- **`RWMutex` blocks new RLock callers once a writer is waiting** (writer-priority). A steady stream of readers can't starve a write, but a write can briefly stall readers. Tune your write cadence accordingly.

## Components

The "components" of a sync.Mutex-vs-sync.RWMutex decision aren't software modules — they're the **lock candidates, runtime conditions you must measure, and the safety/fairness properties that constrain the choice.** Naming them separately means you can swap one (e.g., upgrade Mutex → RWMutex after a benchmark) without re-deriving the whole design.

### Lock candidates

| Primitive | Sizeof + state | Read fast path | Write fast path | When it wins |
|---|---|---|---|---|
| **`sync.Mutex`** | 8 bytes; `state int32` + `sema uint32` | One atomic CAS to acquire; no reader/writer distinction | One atomic CAS | Writes ≥ reads, OR critical section is trivial (single map lookup, counter), OR you don't care to benchmark and want the simplest correct answer. |
| **`sync.RWMutex`** | 24 bytes; 5 coordination fields incl. `readerCount atomic.Int32` | One atomic add to `readerCount` (cache-line invalidation across cores) + writer-presence check | Acquires `w Mutex` then waits for in-flight readers via semaphore | Reads do real work (≥ map operation), reads dominate writes (≥10:1 typical threshold), threads ≥ a few cores. Strongest case: range/iteration over the whole map. |
| **`sync.Map`** | implementation-private; dual `read`/`dirty` maps with amortization | Lock-free read for hot keys (atomic load + map lookup) | Conditional lock-and-promote dirty entries | The two patterns the docs name: (a) write-once-many-read entries; (b) disjoint key sets across goroutines. **Not** a general "concurrent map." |
| **Sharded `Mutex`** (e.g., `[N]struct{m Mutex; data map[K]V}` keyed by `hash(k) % N`) | N × Mutex + N × map | Same as Mutex but on a shard | Same as Mutex but on a shard | High contention on a single map — sharding removes contention rather than optimizing the lock. Often the right answer when the simple Mutex/RWMutex choice still bottlenecks. |
| **Read-only-snapshot pattern** (`atomic.Value` holding `*map[K]V`; writers replace, readers read snapshot) | One pointer | atomic load of `*map[K]V`; map lookup is lock-free over an immutable snapshot | Lock + build new map + atomic store + GC catches the old map | Cache that's mostly read with infrequent bulk writes (cache reload, config refresh). Readers never block. Writes pay the build-and-replace cost. |

### Runtime conditions to measure

These are the inputs that flip the decision. None can be guessed from "read-heavy" alone:

- **Read shape.** Trivial counter? Single map lookup? Lookup + decode + transform? Iterate-all-keys? The benchmark deltas in Architecture span 1× → 6× depending on this.
- **Read:write ratio.** Below ~10:1, RWMutex's coordination tax often wipes out its parallel-reader win.
- **Concurrency level.** Reader-count atomics scale O(GOMAXPROCS) under cache coherence. RWMutex degrades earlier than its "more readers = faster" reputation suggests at high core count.
- **Hold-time distribution.** p50, p99, max time the lock is held under each operation. RWMutex's win comes from overlapping holds; if all holds are sub-µs, there's nothing to overlap.
- **Write cadence and burstiness.** A single periodic writer (e.g., cache reload every 10 s) is friendly to RWMutex; chatty writers (per-request invalidation) erode the read-side win.
- **Iteration / range API presence.** A "list all" or "scan" endpoint dramatically tilts toward RWMutex — those holds are long enough that parallel readers matter.

### Safety / fairness properties

These are not negotiable; they constrain the choice independent of performance:

- **Non-copyable.** Both `Mutex` and `RWMutex` must not be copied after first use. Pass cache structs by pointer; vet API consumers can't accidentally take a value receiver.
- **Non-reentrant.** Same goroutine can't lock twice. Design for "one acquire per critical section"; don't try to escalate `RLock → Lock` (RWMutex explicitly forbids).
- **Writer-priority on `RWMutex`.** Once a writer is waiting, new `RLock` calls block until that writer completes. A reader storm cannot starve a write — but a write briefly stalls readers. Acceptable for caches where writes are rare; problematic if you have unbounded write contention.
- **Memory-model guarantees.** `sync.Mutex` docs spell out the happens-before relationship between Unlock and the next Lock; the same model applies to `RWMutex`. Both are safe building blocks; you don't need to add atomics around the protected data.
- **`sync.Map` has weaker semantics on iteration.** `Range` does not snapshot — concurrent modifications during a Range may or may not appear. If your cache exposes a "list all keys" API, this is a footgun; prefer plain map + RWMutex.

### Measurement instruments

A lock decision without measurement is a guess. The instruments:

- **Go's built-in benchmarks** (`go test -bench=.` with `-benchmem`, `-cpu=1,2,4,8,N`). Run the **actual** workload pattern — point lookup vs full read+decode vs range — separately. The wrong workload measurement (counter benchmark when your real work is map iteration) is how teams pick the wrong primitive.
- **`pprof` mutex contention profile** (`runtime.SetMutexProfileFraction(1)`, then `go tool pprof`). Shows where waits happen and how long; reveals whether the lock IS the cost or the cost is elsewhere.
- **`pprof` block profile** (`runtime.SetBlockProfileRate(1)`). Reveals goroutines parked on lock acquisition specifically.
- **`go test -race`.** Required regardless of lock choice; race detector catches missing synchronization that performance benchmarks won't.
- **Histogram of critical-section duration.** Add timing around the longest 1–2 critical-section paths (typically the iteration / scan path). Tells you which regime in the Architecture table you're actually in.

### Why this decomposition matters

By naming candidates, conditions, and instruments separately, the design supports:

1. **Promotion path.** Ship `Mutex` first; benchmark; promote to `RWMutex` if conditions warrant. Single-line change at the lock declaration; no API churn for callers (lock-acquire wrappers can be `RLock` for reads / `Lock` for writes from day one even with a Mutex backing — methods just both call `Lock`).
2. **Avoidance path.** Recognize when the right answer is "remove contention" (sharding) rather than "tune the lock primitive." The condition signal: contention on the lock dominates total wait time AND adding readers makes it worse, not better.
3. **Re-validation when conditions drift.** Add a "list all" endpoint; rev to RWMutex. Workload becomes write-heavy; rev back to Mutex. Each change is justified by measurement, not folklore.

## Data Flow

This describes the **operational data flow** of a cache acquisition under each primitive — the path from "request arrives" to "value returned" — so you can see exactly where latency, contention, and cache-coherence cost enter.

### `sync.Mutex` (single lock)

```
Goroutine wants cache[k]
  │
  ▼
[Mutex.Lock() — atomic CAS on `state`]
  │
  ├── ✅ Acquired (uncontended)        → enter critical section
  │
  └── ❌ Held by another goroutine
        │
        ▼
   [Spin briefly (active spin), then park via futex/runtime semaphore]
        │
        ▼
   [Holder Unlock() → runtime wakes one waiter]
        │
        ▼
   [Acquired]
   │
   ▼
[Read OR write cache[k]; this thread holds exclusive access]
   │
   ▼
[Mutex.Unlock()]
```

**Key property:** all goroutines, readers and writers alike, serialize through one lock. Even concurrent point-lookup readers wait for each other. Cost per access: ~one atomic op uncontended; futex park/wake under contention.

### `sync.RWMutex` (read-many / write-one)

```
Goroutine wants cache[k] (READ)
  │
  ▼
[RWMutex.RLock() — atomic.AddInt32(&readerCount, 1)]   ← cache-line invalidation across cores
  │
  ├── No writer waiting → ✅ Acquired in parallel with other readers
  │
  └── Writer waiting (readerCount went negative) → park on readerSem
        │
        ▼
   [Writer completes; runtime wakes parked readers]
        │
        ▼
   [Acquired]
   │
   ▼
[Read cache[k]; OTHER readers may also be inside the critical section concurrently]
   │
   ▼
[RWMutex.RUnlock() — atomic.AddInt32(&readerCount, -1); if zero and writerWaiting, wake writer]


Goroutine wants cache[k]=v (WRITE)
  │
  ▼
[RWMutex.Lock() — acquires inner `w Mutex` (excludes other writers)]
  │
  ▼
[atomic.AddInt32(&readerCount, -rwmutexMaxReaders)]   ← signals readers to drain
  │
  ▼
[Wait for in-flight readers via writerSem (readerWait counts down)]
  │
  ▼
[Acquired exclusive]
  │
  ▼
[Update cache[k]; no other goroutines inside]
  │
  ▼
[RWMutex.Unlock() — restore readerCount, wake any parked readers]
```

**Key property:** readers run in parallel as long as no writer is queued. Writers serialize and briefly stall reads. Cost per RLock: one atomic add (cache-coherence cost across all cores that hold readerCount in their L1) + writer-presence check.

**Failure mode:** under high reader concurrency, the cache line containing `readerCount` ping-pongs between cores. The "more readers = faster" intuition fails when this overhead exceeds the parallelism benefit — typically when the critical section is too short to amortize the atomic.

### `sync.Map` (specialized, for reference)

```
Goroutine wants cache[k] (READ via .Load)
  │
  ▼
[Atomic load of read-only `read` map]
  │
  ├── Key found → ✅ return (LOCK-FREE — no atomic on the read path itself)
  │
  └── Key not found in `read`
        │
        ▼
   [Acquire mu (Mutex), check `dirty` map, possibly promote]
        │
        ▼
   [Return]


Goroutine wants cache[k]=v (WRITE via .Store)
  │
  ▼
[Atomic load of `read`; if k present and not deleted → atomic CAS → done]
  │
  └── Else
        │
        ▼
   [Acquire mu, write to `dirty`, possibly trigger promotion to `read`]
```

**Key property:** hot-key reads are fully lock-free. Cold/missing keys take the slow path. Writes amortize the dirty→read promotion. Fits the docs' two patterns: write-once-read-many (the read-only `read` map gets all the lookups) and disjoint key sets (no inter-goroutine contention).

### Sharded `Mutex` (contention removal)

```
Goroutine wants cache[k]
  │
  ▼
[shard_idx = hash(k) % N]
  │
  ▼
[shards[shard_idx].mu.Lock() — different k usually hits different shard]
  │
  ▼
[Read/write shards[shard_idx].data[k]]
  │
  ▼
[shards[shard_idx].mu.Unlock()]
```

**Key property:** N independent locks → 1/N contention probability under uniform key distribution. Trades memory (N maps) for parallelism. Combines with Mutex OR RWMutex per shard; usually plain Mutex per shard suffices because per-shard contention is already low.

### Read-only-snapshot (atomic.Value)

```
Goroutine wants cache[k] (READ)
  │
  ▼
[snapshot = atomic.Value.Load() → *map[K]V]
  │
  ▼
[Lookup snapshot[k] — completely lock-free; snapshot is immutable]
  │
  ▼
[Return]


Goroutine reloads the cache (WRITE — bulk)
  │
  ▼
[mu.Lock()  — only one writer at a time]
  │
  ▼
[Build new map, populate, ...]
  │
  ▼
[atomic.Value.Store(newPtr)]   ← readers from now on see the new map
  │
  ▼
[mu.Unlock()]
   │
   ▼
[Old map drops out of scope; GC reclaims when no readers reference it]
```

**Key property:** readers never block, never atomic-op (beyond the initial pointer load). Writers pay full rebuild cost. Best when reads vastly outnumber writes AND writes are infrequent bulk operations (config reload, periodic refresh).

### Where the metadata cache fits

The recommendation in Architecture (start with `Mutex`, promote to `RWMutex` if benchmarks justify) maps to the data flows like this:

- **Default path (Mutex):** every cache hit takes one atomic CAS uncontended; under contention, brief spin then park. p50 ~10 ns; p99 governed by goroutine wakeup latency.
- **Promoted path (RWMutex), when reads do real work:** point lookups become parallel; writes briefly stall reads; per-read cost adds the cache-line-bouncing atomic add. p50 ~15–20 ns per RLock; aggregate throughput much higher when readers overlap.
- **Promoted path (RWMutex), when reads are trivial:** worse than Mutex — the per-RLock cost exceeds the parallelism win. The benchmark would show this; the design tells you to expect it.
- **Fallback to lock-free patterns:** if even RWMutex contends under load, restructure to `atomic.Value` (snapshot) or sharded Mutex (parallelism) — different decision class, separate spec.

The data flow makes the decision concrete: the lock primitive shapes what happens between "request arrives" and "value returned." Pick the one whose shape matches your actual read/write distribution; benchmark in production-shaped conditions before committing.

## Error Handling

The "errors" in a sync.Mutex / sync.RWMutex decision aren't exceptions Go throws — they're the **failure modes that turn a wrong choice or wrong usage into a production incident**, plus the patterns that contain the blast radius.

### Failure modes by primitive

| Primitive | Failure mode | Symptom | Containment |
|---|---|---|---|
| **`sync.Mutex`** | Deadlock from inverted lock-order across two locks | Goroutines hang at `sync.Mutex.Lock`; `pprof goroutine` shows ring of waiters; `runtime/debug.SetTraceback("all")` + SIGQUIT prints stacks | Document acquisition order at each lock declaration; static analysis (`staticcheck` SA9006/SA9007 family); always acquire in a fixed order; consider a single composite lock if two locks are always co-acquired. |
| **`sync.Mutex`** | Holder panicked without `defer Unlock()` | Lock held forever; all subsequent acquirers hang | **Always** use `defer mu.Unlock()` immediately after `mu.Lock()`. Code review checklist; `go vet` doesn't catch this — habit + lint do. |
| **`sync.Mutex`** | Sleeping under the lock (network call, channel send, `time.Sleep`) | Latency spike on every contended acquire; tail latency stretches; throughput drops under load | Move blocking operations OUT of the critical section. Pattern: read state under lock → release → do I/O → re-acquire if needed to commit. The lock should hold for tens of nanoseconds, not milliseconds. |
| **`sync.Mutex`** | Lock copied (passed by value) | Two goroutines acquire "different" locks both protecting same data → race condition | `go vet`'s `copylocks` check catches this. Pass by pointer; embed Mutex as a value field, not as `*Mutex`; method receivers should be pointer receivers. |
| **`sync.RWMutex`** | RLock held while doing write-shaped work | Writer starvation in practice (writer waits for "drain" but readers keep coming); p99 write latency stretches indefinitely | Audit critical-section bodies: anything mutating goes under `Lock`, not `RLock`, even if "we just touch one field." |
| **`sync.RWMutex`** | Recursive `RLock` (same goroutine takes RLock twice) | Specified by docs as forbidden; deadlock risk if a writer waits between the two RLocks (writer-priority blocks the second RLock; first RLock blocks the writer) | Don't structure code to need recursive RLock. If a method calling another method both want the read lock, refactor: caller takes it once, callee assumes the lock is held (document this in the function signature/comment). |
| **`sync.RWMutex`** | Attempted `RLock → Lock` upgrade in same goroutine | Deadlock (waiting for self) | Forbidden by docs. Pattern: release RLock, take Lock, **re-validate state** (it may have changed), then proceed. Or: take Lock from the start if you know you might need to write. |
| **`sync.RWMutex`** | False sharing — RWMutex field shares cache line with hot data | Adjacent struct fields experience cache-line bouncing on every RLock; throughput stalls in ways that look like lock contention but are cache contention | Cache-line-pad the lock: put the Mutex in its own cache line via `_ [64]byte` padding fields. Useful regardless of Mutex/RWMutex choice. |
| **`sync.Map`** | Treating it as drop-in for `map[K]V`+lock | Type assertions everywhere (`.Load() returns interface{}`); silent semantic differences (Range doesn't snapshot; Len() doesn't exist; LoadOrStore subtleties) | Don't reach for `sync.Map` reflexively. Use plain map + Mutex/RWMutex unless your usage matches one of the two patterns the docs name. |
| **Sharded Mutex** | Hash-collision degenerate distribution | All hot keys land in one shard → reverts to single-Mutex behavior + N-1 wasted shards' memory | Use a high-quality hash (xxhash, fnv); benchmark with realistic key skew; size N to ~2-4× expected concurrent goroutines. |
| **`atomic.Value` snapshot** | Reader holds reference to old snapshot past safe point | Memory grows because GC can't reclaim old maps; stale reads | Be explicit: readers should call `Load()`, use the result locally, return; don't store the loaded `*map` long-term. Document the "snapshot is read-only and may go stale" contract. |

### Cross-cutting safety nets

- **`go test -race` in CI, always.** Catches every class of missing-synchronization bug regardless of which primitive you chose. Cost: ~2× slower tests; benefit: catches the bug before production.
- **`runtime.SetMutexProfileFraction(1)` in pre-production stress tests.** Reveals *where* the contention is concentrated; tells you whether the lock primitive is even the bottleneck before you waste time choosing between Mutex and RWMutex.
- **`runtime.SetBlockProfileRate(1)` in pre-production.** Reveals goroutines parked on lock acquisition vs. parked on channels vs. parked on I/O; correctly attributes latency.
- **Tail-latency SLO on cache acquisition.** Treat p99 lock-wait time as a first-class metric. Healthy: p99 < 1ms (Mutex/RWMutex without contention). Stressed: p99 > 10ms suggests preemption-while-holding, scope creep, or wrong primitive.
- **A `// LOCK ORDER:` comment** at the top of any file with multiple locks. The next engineer adding code shouldn't have to git-blame to discover the convention.
- **Periodic re-validation in load tests.** Lock choice depends on workload conditions (read:write ratio, hold time, concurrency). Code reviews don't catch workload drift; recurring load tests do. When the workload shifts (new endpoint, more nodes, scale-up), re-run the lock benchmark.

### What "wrong" looks like in production

A team that picked `RWMutex` reflexively for "read-heavy" without measuring the read shape will see one of:

1. **CPU usage rises with load but throughput plateaus.** Cache-line bouncing on `readerCount` between cores; adding goroutines adds atomics, not parallelism.
2. **Tail latency grows under writer contention.** Writes are rare but stall a backlog of readers each time. p99 write latency >> mean.
3. **Write throughput collapses at high reader concurrency.** Writer waits for `readerWait` to drain; under storm of readers, drain never completes (writer-priority helps but isn't a panacea if readers are unbounded).
4. **No visible improvement vs Mutex baseline.** The "more readers = faster" promise didn't materialize because the critical section was too short. Now you're paying RWMutex's overhead with no win — strictly worse than Mutex.

A team that picked `Mutex` and shipped without benchmarking will see:

1. **Acceptable performance for a long time.** Mutex on a small metadata cache is rarely the bottleneck — request-handling and I/O dominate.
2. **One day, a long-iteration code path lands** ("show me all 10,000 cached entries"). Mean latency triples because every concurrent reader serializes. **This** is when you do the benchmark and promote to `RWMutex`.

A team that picked `sync.Map` reflexively will see:

1. **Weird interface{}-everywhere code** that's hard to refactor.
2. **Subtle bugs in iteration** because Range doesn't snapshot.
3. **Worse performance** than plain map + Mutex outside the two patterns the docs name.

The architecture's "start with Mutex, measure, promote if justified" recipe is robust against all three failure modes. The key is the **measure** step — without it, the promotion is a guess and you've added complexity without justification.

## Testing

The testing strategy for a sync.Mutex / sync.RWMutex decision has three tiers — each catches a different class of regression. **Skip any tier and you ship a guess.**

### Tier 1 — Correctness (must pass before any perf claim)

Goal: prove the lock primitive doesn't introduce data races, deadlocks, or use-after-free.

| Test | Tool | What it catches |
|---|---|---|
| **Race detector run of the cache exerciser** | `go test -race -count=10` (multiple iterations to surface flaky races) | Data races; missing synchronization; unprotected map access. Must run before any perf benchmark. |
| **Concurrent `Get`/`Set` stress test** | `t.RunParallel` with N=100+ goroutines mixing reads and writes | Surfaces the failure modes Mutex/RWMutex are meant to prevent. |
| **Lock-order test** (if cache holds 2+ locks) | Custom harness — goroutine A: lock1→lock2; goroutine B: lock2→lock1; random delays | Forces deadlock if lock-order convention isn't followed. |
| **Range-during-write test** | Goroutine A iterates the cache while goroutine B inserts; assert no panic, no infinite loop, terminates | For Mutex/RWMutex: should be safe (writer waits, reader sees consistent snapshot). For `sync.Map.Range`: documents the "may or may not see in-progress writes" semantics. |
| **Copylocks vet check** | `go vet ./...` | Catches accidental Mutex copy via value-receiver method or struct value-copy. |
| **Goroutine-leak test** | `goleak.VerifyNone(t)` after each test | Surfaces lock-deadlock that leaves goroutines parked. |

### Tier 2 — Performance (only after Tier 1 is green)

Goal: validate that the chosen primitive meets the latency / throughput SLO under realistic load.

```go
// Bench template — run against your cache type:
func BenchmarkMutex_PointLookup(b *testing.B) {
    c := NewCacheWithMutex()
    populate(c, 10_000)
    b.ResetTimer()
    b.RunParallel(func(pb *testing.PB) {
        for pb.Next() {
            _ = c.Get(randomKey())
        }
    })
}

func BenchmarkRWMutex_PointLookup(b *testing.B)        { /* same shape, RWMutex backing */ }
func BenchmarkMutex_RangeAll(b *testing.B)             { /* range over all keys */ }
func BenchmarkRWMutex_RangeAll(b *testing.B)           { /* range over all keys */ }
func BenchmarkMutex_LookupAndDecode(b *testing.B)      { /* lookup + JSON-decode value */ }
func BenchmarkRWMutex_LookupAndDecode(b *testing.B)    { /* lookup + JSON-decode value */ }
func BenchmarkMutex_MixedReadWrite(b *testing.B)       { /* 90% reads, 10% writes */ }
func BenchmarkRWMutex_MixedReadWrite(b *testing.B)     { /* 90% reads, 10% writes */ }
```

Run the matrix:

```
for cores in 1 2 4 8 $(nproc); do
  go test -bench=. -benchmem -cpu=$cores -count=10 \
    | tee bench-$(date +%s)-cores$cores.txt
done

# Then compare with benchstat:
benchstat bench-*-cores1.txt bench-*-coresN.txt
```

Pass criteria for the chosen primitive:

- **Mutex baseline**: throughput should scale roughly with cores until contention takes over (typically beyond ~4-8 cores for a busy cache).
- **RWMutex (if chosen)**: must visibly beat Mutex on the **specific workload pattern your cache actually does**. The benchmark deltas should match Architecture's table direction:
  - Point lookup: tied or slight RWMutex win acceptable.
  - Range/iteration: RWMutex should be 3-6× faster.
  - Mixed read+decode: RWMutex should be 2-5× faster.
  - Write-heavy: RWMutex should NOT be slower than Mutex by more than ~10%; if it is, drop RWMutex.
- **CV (variance/mean) < 0.2** across runs at high concurrency. RWMutex with high CV under reader storms is the cache-line-bouncing signature — fall back to Mutex or shard.

### Tier 3 — Production observability (the long-running test)

Goal: detect drift after deployment.

| Signal | Source | Alert threshold |
|---|---|---|
| **Lock-acquire p99 latency** | `runtime.SetMutexProfileFraction(1)` + periodic `pprof` snapshot | p99 > 10× baseline for 5 min → page; p99 > 100× → critical. |
| **`runtime.SetBlockProfileRate(1)`** snapshot | Continuous profiling agent (e.g., Pyroscope, Parca) | Sudden growth in goroutines parked at `sync.Mutex.Lock`/`RLock` → contention regression. |
| **Cache-hit / cache-miss ratio** | Application metric on every Get | Drift in ratio invalidates the workload assumption that drove the lock choice. Re-benchmark when ratio shifts. |
| **Goroutine count at the cache code-path** | Application metric — count concurrent in-flight `Get`/`Set` calls | If concurrency rises above what was benchmarked, re-validate the primitive. |
| **Critical-section duration histogram** | `time.Since(start)` around the longest 1-2 critical sections, exported as a histogram metric | Hold time crept above the threshold the design assumed → primitive choice may need re-validation. |

### Tier-3 test you actually run before tagging

```bash
# Minimal pre-deploy smoke (bash + go bench)
go test -race -count=5 ./cache/... \
  || { echo "RACE DETECTED — do not ship"; exit 1; }

go test -bench=. -benchmem -cpu=$(nproc) -count=10 ./cache/... \
  | tee /tmp/bench-current.txt

benchstat /tmp/bench-baseline.txt /tmp/bench-current.txt \
  | tee /tmp/bench-delta.txt

# Fail the deploy if any benchmark regressed > 20%
awk '/[+−]/ && $NF+0 > 20.0 { print; bad=1 } END { exit bad }' /tmp/bench-delta.txt \
  || { echo "BENCHMARK REGRESSION — investigate"; exit 1; }
```

### What this testing plan deliberately does NOT do

- **No "sync.Map is faster than Mutex on my laptop with 1 goroutine" test.** Single-goroutine uncontended is the case where every primitive wins; emphasizing it produces wrong conclusions.
- **No micro-optimization of `runtime.SetMutexProfileFraction` thresholds.** Default = 0; turn on with 1 in dev/staging; turn off in production hot paths if profile cost is measured > 1%. Don't tune the profiler before tuning the lock.
- **No "lock-free is always better" rabbit hole.** Lock-free cache designs (e.g., `atomic.Value` snapshot, shard arrays with atomic CAS per slot) are a different decision class. If the workload genuinely justifies them, they get a separate spec, not a footnote here.
- **No "RWMutex must always be faster for reads" assumption.** The whole point of the architecture is that this assumption is false in many realistic regimes.

The testing strategy is the same shape as the decision: **measure under realistic conditions, treat variance as a first-class signal, and reject anecdotes (your own or someone else's) without a benchmark to back them.**

