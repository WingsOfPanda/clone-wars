# Decide Between Lru A Design

**Goal:** The eviction subsystem exposes a single pluggable `EvictionPolicy` interface; the policy is selected at startup via config (`policy: lru | lfu | w-tinylfu | arc`) and is hot-swappable on cache restart, not at runtime. **Default: LRU** for general-purpose workloads with changing access patterns ([docs.python.org/3.10/library/functools.html](https://docs.python.org/3.10/library/functools.html), [redis.io/docs/.../eviction/](https://redis.io/docs/latest/develop/reference/eviction/) calls `allkeys-lru` a good default with no stronger reason to choose another).

**Architecture:** ## Per-policy fixed properties

**Tech Stack:**
- pluggable `EvictionPolicy` interface (LRU / LFU / W-TinyLFU / ARC)
- O(1) hashmap + doubly-linked-list (LRU); count-min sketch (W-TinyLFU); ghost-list directory (ARC)
- Operator-facing telemetry via Redis-style `INFO` counters
- Sampling-based approximation for LRU/LFU (Redis default N=5; tunable via `policy-samples`)

---

## Architecture

The eviction subsystem exposes a single pluggable `EvictionPolicy` interface; the policy is selected at startup via config (`policy: lru | lfu | w-tinylfu | arc`) and is hot-swappable on cache restart, not at runtime. **Default: LRU** for general-purpose workloads with changing access patterns ([docs.python.org/3.10/library/functools.html](https://docs.python.org/3.10/library/functools.html), [redis.io/docs/.../eviction/](https://redis.io/docs/latest/develop/reference/eviction/) calls `allkeys-lru` a good default with no stronger reason to choose another).

## Per-policy fixed properties

These do not vary with workload; they are properties of the algorithm.

| Policy | CPU/access | Memory overhead/entry | Scan-resistance | Notes |
|---|---|---|---|---|
| **LRU** | O(1) — list-move + hashmap [Caffeine Design] | 2 pointers + hashmap slot | **No** — full scan flushes warm set [Wikipedia] | Redis approximates via N-key sampling (default `maxmemory-samples 5`) |
| **LFU (with decay)** | O(log N) exact; O(1) sampled (Redis) | counter + decay clock; Redis uses 8-bit log counter | Partial (decay-dependent) | Redis: `lfu-decay-time`, `lfu-log-factor`, default decay 1m, counter saturation ~1M req |
| **W-TinyLFU** | O(1) lookup + admission [Caffeine Design] | 4-bit count-min sketch ~8 bytes/entry; sketch unused under 50% capacity | **Yes** — recency window absorbs scans, frequency filter rejects one-shots | Caffeine ships it for Java; specific "within 1% of Belady" claim is **CONTESTED** |
| **ARC** | O(1) per request [Megiddo & Modha] | ~4 pointers/slot + ghost lists 2× cache size | **Yes** — adaptive T1/T2 split | Caffeine flags ARC as patented; reference impl in ZFS |

## Workload × policy decision matrix

`Strong / Moderate / Weak / Catastrophic` indicates hit-rate signal; CPU/Mem/Scan are taken from the per-policy table above.

| Workload | LRU | LFU | W-TinyLFU | ARC |
|---|---|---|---|---|
| General-purpose changing | **Strong** (recency dominates) | Weak-to-moderate (lags drift) | **Strong** | **Strong** |
| Stable-skew (Zipfian, hours-days) | Moderate | **Strong** (designed for this) | **Strong** (TinyLFU's home turf) | **Strong** |
| Read-heavy, rare writes | **Strong** if WS fits | **Strong**, stale-pop risk | **Strong** | **Strong** |
| Scan-heavy | **Catastrophic** | Moderate | **Strong** (designed-for) | **Strong** (designed-for) |
| Mixed (recency + frequency) | Moderate | Moderate | **Strong** (Caffeine's primary win case) | **Strong** |

## Architecture implications

1. **Default to LRU + observation loop.** Ship with `policy: lru`, expose Redis-style `INFO` counters (`keyspace_hits`, `keyspace_misses`, `evicted_keys`); recommend a measurement period before any policy change.
2. **Switch to LFU only with evidence of stable skew + decay tuning.** Without `lfu-decay-time` set, stale popularity dominates after access patterns shift.
3. **Prefer W-TinyLFU for embedded/local cache** when implementation dependency is acceptable and scan or mixed workloads are expected — it is the cleanest source-backed balance of O(1) CPU, ~8 bytes/entry overhead, recency+frequency adaptation, and scan-resistance, *without* ARC's ghost-key retention.
4. **Treat ARC as algorithmic reference unless licensing is acceptable.** Self-tuning and scan-resistance are strong, but Caffeine docs flag the patent.
5. **CPU/Mem cost only matters at very high RPS or sub-100-byte entries.** At 1k–10k RPS with KB-sized values, the per-access difference between LRU and W-TinyLFU is in the noise relative to hit-rate gain.

## Tech Stack
- pluggable `EvictionPolicy` interface (LRU / LFU / W-TinyLFU / ARC)
- O(1) hashmap + doubly-linked-list (LRU); count-min sketch (W-TinyLFU); ghost-list directory (ARC)
- Operator-facing telemetry via Redis-style `INFO` counters
- Sampling-based approximation for LRU/LFU (Redis default N=5; tunable via `policy-samples`)

## Components

All four policies implement a single `EvictionPolicy` interface. The cache itself does not know which policy is active — it dispatches via the trait. Total surface: ~1,400 LOC core + ~80 LOC telemetry. Per-policy LOC numbers are estimates from comparable open-source implementations (Caffeine, Redis); use as scoping signals, not contract.

## 1. `EvictionPolicy` trait (~50 LOC)

The single point of polymorphism. Methods:

- `record_access(key)` — called on every cache hit; LRU moves to front, LFU bumps counter, W-TinyLFU records to admission filter.
- `select_victim() -> Option<Key>` — called when capacity is full and a new entry must be inserted.
- `on_insert(key)` — called after a new entry is placed in the cache.
- `on_remove(key)` — called when an entry is explicitly invalidated (TTL expiry, manual delete).
- `name() -> &'static str` — returned by `INFO` for telemetry.

## 2. `LruPolicy` (~150 LOC)

Standard doubly-linked list + hashmap. Textbook implementation.

## 3. `LfuPolicy` (~250 LOC)

Redis-style: 8-bit logarithmic counter per entry + decay clock. Sampled victim selection (default N=5, tunable via `policy_samples`) — same approximation Redis uses to avoid maintaining a full priority queue.

Two config knobs surfaced:
- `lfu_log_factor` — counter increment probability (Redis default).
- `lfu_decay_time_s` — decay interval (Redis default 60s).

## 4. `WTinyLfuPolicy` (~400 LOC)

Port of Caffeine's W-TinyLFU: 1% LRU recency window + 99% main cache governed by TinyLFU admission filter (4-bit count-min sketch, ~8 bytes/entry). Sketch unused under 50% capacity.

Citations: [Caffeine Design wiki](https://github.com/ben-manes/caffeine/wiki/Design), [TinyLFU paper (Einziger, Friedman, Manes 2015)](https://arxiv.org/abs/1512.00727).

## 5. `ArcPolicy` (~350 LOC)

Port of Megiddo & Modha's ARC: T1/T2 LRU lists + B1/B2 ghost lists, adaptive split parameter `p`. Citation: [ARC paper](https://www.cs.cmu.edu/~natassa/courses/15-721/papers/arcfast.pdf).

**Conditional on patent review** — ship behind a `#[cfg(feature = "arc-policy")]` flag so users opt in.

## 6. `PolicyRegistry` (~30 LOC)

`from_config(yaml) -> Box<dyn EvictionPolicy>`. Maps config string → constructor. Validates `policy` field at startup; refuses unknown values.

## 7. `CacheStats` (~80 LOC)

Counters surfaced over a Redis-style `INFO` endpoint: `hits`, `misses`, `evictions`, `policy_name`, `policy_samples`, plus per-policy specifics:

- LFU: counter histogram.
- W-TinyLFU: window/main split, sketch active flag.
- ARC: current `p` value (T1/T2 split).

All atomic increments; no per-access lock.

## 8. `PolicyTuner` (deferred, v2 only)

Runs in-process, samples `keyspace_hits` over rolling windows, log-warns when current policy underperforms a heuristic baseline (e.g., LRU hit rate < 85% on a stable-popularity signal suggests LFU). Does **not** auto-switch — operator-in-loop only.

## Data Flow

## Read path (cache hit or miss)

```
client.get(key)
    ↓
Cache::get(key)
    ├── hashmap.get(key) → Some(value)?
    │     ├── Yes  → policy.record_access(key); stats.hits++; return value
    │     └── No   → stats.misses++; return None
```

## Write path (cache insert)

```
client.put(key, value)
    ↓
Cache::put(key, value)
    ├── hashmap.contains(key)?
    │     ├── Yes  → hashmap[key] = value; policy.record_access(key); return
    │     └── No   → goto INSERT_FLOW

INSERT_FLOW:
    ├── len < capacity?
    │     ├── Yes  → hashmap.insert(key, value); policy.on_insert(key); return
    │     └── No   → goto EVICT_THEN_INSERT

EVICT_THEN_INSERT:
    ├── victim = policy.select_victim() → Some(victim_key)?
    │     ├── Yes  → hashmap.remove(victim_key); policy.on_remove(victim_key);
    │     │         stats.evictions++;
    │     │         hashmap.insert(key, value); policy.on_insert(key); return
    │     └── None → log_error; return Err(CacheFullError)
```

## Per-policy `select_victim()` flow

- **LRU**: pop tail of access-order list. O(1).
- **LFU**: sample `policy_samples` keys uniformly at random; among the sample, return the one with the lowest counter (Redis-style approximation). O(N) where N = sample size, default 5.
- **W-TinyLFU**: pop tail of recency window → TinyLFU admission filter compares window-victim's frequency vs. main-cache-victim's frequency → evict the lower-frequency of the two; the higher-frequency one stays in the main cache. O(1).
- **ARC**: based on current `p` parameter, choose T1 or T2 to evict from; record the evicted key to B1 or B2 (ghost list); future hits on the ghost list adjust `p`. O(1).

## Telemetry flow (operator)

```
operator → HTTP GET /info
    ↓
CacheStats::dump_redis_format()
    ├── stats.hits, stats.misses, stats.evictions  (atomic loads)
    ├── policy.name()
    ├── policy.detail_dump()  (LFU counter histogram, W-TinyLFU split, ARC p)
    └── format as Redis-style INFO key:value lines
        ↓
    return 200 OK + body
```

## Startup flow (cache instantiation)

```
Cache::from_config(yaml)
    ├── PolicyRegistry::from_config(yaml.policy_string) → Box<dyn EvictionPolicy>
    │     ├── "lru"        → LruPolicy::new()
    │     ├── "lfu"        → LfuPolicy::new(yaml.lfu_log_factor, yaml.lfu_decay_time_s)
    │     ├── "w-tinylfu"  → WTinyLfuPolicy::new(yaml.capacity)
    │     ├── "arc"        → #[cfg(feature = "arc-policy")] ArcPolicy::new(yaml.capacity)
    │     └── unknown      → return Err(ConfigError)
    └── Cache { policy, hashmap, stats, capacity }
```

## Concurrent access

All four policies wrap their internal data structures in a `RwLock`. Cache `get()` takes a read-lock for `record_access()` and a write-lock for hashmap mutation only when the policy needs to mutate access order (LRU does on every read; W-TinyLFU buffers reads then drains under write-lock periodically — a Caffeine optimization). LFU/ARC similar. Lock granularity is per-cache-instance, not per-key — trade-off favors simplicity over throughput at high contention.

## Error Handling

## 1. `CacheFullError` — `select_victim()` returns `None`

Degenerate case: cache full but policy cannot pick a victim. Should be unreachable in practice; treated as a bug-trap.

- Log error with policy name + cache state snapshot.
- Return `Err(CacheFullError)` to caller — caller decides whether to retry, drop, or panic.

## 2. Config validation at startup

All `ConfigError` variants prevent cache instantiation:

- Unknown `policy` string → `ConfigError("unknown policy: <name>")`.
- Non-positive `capacity` → `ConfigError("capacity must be positive")`.
- LFU `decay_time_s ≤ 0` → `ConfigError("lfu_decay_time_s must be > 0")`. Without decay, LFU pollution is guaranteed ([redis.io/docs/.../eviction/](https://redis.io/docs/latest/develop/reference/eviction/)).
- LFU `log_factor` outside `[0, 255]` → `ConfigError`.
- W-TinyLFU `capacity < 16` → `ConfigError("w-tinylfu requires capacity >= 16")` — sketch initialization needs a minimum size.
- ARC requested without feature flag → `ConfigError("arc policy not compiled in; rebuild with --features arc-policy")`.

## 3. Counter saturation (LFU)

Redis 8-bit logarithmic counter saturates at 255 (~1M increments per key, per Redis docs). Beyond that, new accesses are no-ops at the counter level. Decay (every `lfu_decay_time_s`) decrements all counters proportionally — without it, saturation persists indefinitely.

Logged at `WARN` if >10% of counters reach saturation in a 1-minute window — signal to tune `log_factor` or decrease `decay_time_s`.

## 4. Sketch overflow (W-TinyLFU)

Count-min sketch has 4-bit cells; overflow at 15. Caffeine handles this with periodic halving of all sketch cells (the "aging" step) — port preserves this.

Aging interval is dynamic: triggered when total insertion count exceeds the sketch reset threshold (Caffeine: `samples`). Not operator-tunable in v1.

## 5. Ghost list memory pressure (ARC)

B1/B2 ghost lists hold up to `2 * capacity` entries each (key + minimal metadata, no value). Worst case: 4× cache memory just for evicted-key history.

For very large caches (millions of entries), this is non-trivial. Operator surfaces ghost list size via `INFO`.

## 6. Operator policy switch

Cache config reload (`SIGHUP` or restart) re-parses the `policy` field. **No live policy switch** — the new policy starts with empty state; cache is effectively cold-started for the eviction subsystem (hashmap entries persist; access metadata does not).

Logged at `INFO`: `policy switched: lru → w-tinylfu (cache state retained, eviction metadata reset)`.

## 7. Concurrent eviction race

Two `put()` calls hit a full cache simultaneously. Both attempt `select_victim()`. The per-cache `RwLock` serializes them; the second call sees the post-eviction state. No double-evict possible.

## Out of scope

- Disk-backed eviction logs (memory-only cache).
- Persistence across restarts (cache is volatile by design).
- Cross-instance coherence (single-process cache; clustering is the caller's problem).
- Auto-recovery from corrupted policy state (operator restarts the process).

## Testing

Three test tiers: per-policy unit, cross-policy regression on synthetic traces, operator-facing telemetry contract.

## Tier 1 — Per-policy unit tests

One file per policy.

- **`test_lru_policy.rs`** — insert N=10 → access 0,1,2 → insert 11th → assert 3 evicted (oldest non-accessed). Cover: empty cache, capacity-1 cache, repeated access of same key, removal during iteration.
- **`test_lfu_policy.rs`** — counter saturation at 255, decay reduces counters proportionally, sampled victim selection prefers lowest counter in sample. Cover: log-factor 0 (counter never increments), decay-time 1s (rapid pollution clearance), sample size N=1 (degenerates to random).
- **`test_w_tinylfu_policy.rs`** — 1%/99% window/main split holds at capacity ≥100; sketch unused under 50% capacity (per Caffeine spec); admission filter rejects one-shot scan items. Cover: capacity boundary at 16 (minimum), sketch aging, window→main promotion of frequent items.
- **`test_arc_policy.rs`** — T1/T2 split adapts under varying recency-vs-frequency mix; B1/B2 ghost hits adjust `p`; ghost list bounded at `2 * capacity`. Cover: pure-recency workload (`p` → 0), pure-frequency (`p` → capacity), 50/50 mix.

## Tier 2 — Cross-policy regression suite

`test_workload_regression.rs`.

Four synthetic trace generators emit `Vec<Key>` access streams:

- `gen_general_changing(n)` — keys drawn from a window that shifts every `n/10` accesses.
- `gen_stable_skew(n)` — 80/20 Zipfian, never shifts.
- `gen_scan_heavy(n)` — 10% hot keys + 90% sequential cold scan.
- `gen_mixed(n)` — 50% recency-driven + 50% frequency-driven, interleaved.

For each (workload, policy) cell in the matrix, run trace → measure hit rate → assert against expected qualitative band: `Strong >70%`, `Moderate 40-70%`, `Weak <40%`, `Catastrophic <10%`. Bands are loose; goal is to catch regressions where a policy moves from `Strong` → `Weak`, not exact-number matching.

Test runtime budget: <5 seconds per cell, ~100 cells total. Run on every CI commit.

## Tier 3 — Operator-facing telemetry contract

`test_info_endpoint.rs`.

- `INFO` returns Redis-format key:value lines.
- `policy_name` always present and matches config.
- `hits + misses == total accesses` (sanity).
- Per-policy specifics surface correctly: LFU counter histogram has 256 buckets; W-TinyLFU exposes `window_size` + `main_size`; ARC exposes `p`.
- `keyspace_hits` / `keyspace_misses` counters are atomic (no torn reads under concurrency).

## Manual benchmarks (not gated on CI)

- `bench_eviction_throughput.rs` — ops/sec for each policy at 1k, 10k, 100k QPS. Report ratio: LRU baseline (=1.0), others as multiples.
- `bench_memory_per_entry.rs` — actual heap bytes per entry for each policy. Validate against the 8 bytes/entry W-TinyLFU spec, ~4 pointers ARC spec.

## Out of scope

- Property-based testing (would catch deeper invariants but adds a heavyweight dep).
- Real-trace replay (e.g., Memcached operational traces). Defer to v2 after the synthetic suite stabilizes.
- Concurrent-access stress test under arbitrary thread counts. Lock-correctness is covered by `RwLock` semantics; chaos testing is overkill for a single-process cache.
- Eviction-fairness tests (no two policies are required to make the same choice on identical input — only required to be in the same hit-rate band).

