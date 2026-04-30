# Decide Between Mutex Vs Spin-lock For A Hot Small Foo Cache Design

**Goal:** [https://man7.org/linux/man-pages/man3/pthread_mutex_lock.3p.html] A POSIX mutex blocks the caller until the mutex becomes available, which makes it a safer default when contention can last longer tha

**Architecture:** **The empirical surprise that overrides folk wisdom:** matklad's benchmark on x86_64 Linux with 32 threads contending shows `parking_lot::Mutex` at 68 ms vs `spin::Mutex` at 142 ms (2 locks, extreme contention); 10 ms vs 55 ms (64 locks, heavy contention). Spinlock variance was 6–123 ms across runs because preempted lock-holders strand spinning waiters. The folk belief "spinlock beats mutex for short critical sections" is contradicted by measurement on the very workload it claims to win.

**Tech Stack:**
- (see Components section)

---

## Architecture

**Recommendation: use a high-quality user-space mutex (e.g., `parking_lot::Mutex`, Windows `CRITICAL_SECTION`, Linux kernel `mutex` in-kernel) by default, NOT a hand-rolled spinlock.** A modern adaptive mutex is already a "spin-then-park" hybrid — it gives you the short-critical-section win of spinning AND the correctness-under-preemption of blocking. Reaching for a bare spinlock means re-implementing (badly) what the platform mutex already does well.

**The empirical surprise that overrides folk wisdom:** matklad's benchmark on x86_64 Linux with 32 threads contending shows `parking_lot::Mutex` at 68 ms vs `spin::Mutex` at 142 ms (2 locks, extreme contention); 10 ms vs 55 ms (64 locks, heavy contention). Spinlock variance was 6–123 ms across runs because preempted lock-holders strand spinning waiters. The folk belief "spinlock beats mutex for short critical sections" is contradicted by measurement on the very workload it claims to win.

**Decision tree:**

1. Are you in user space? → **Use the platform's adaptive mutex.** Done. (`parking_lot::Mutex` for Rust, `std::mutex` + `lock_guard` for C++, Windows `CRITICAL_SECTION` with non-zero spin count, pthread mutex on POSIX.)
2. Are you in kernel / interrupt / atomic context where you cannot sleep? → **`spinlock_t`** (per the Linux kernel `locktypes.html` rules).
3. Is the critical section a tiny non-sleeping core-code path measured to need raw spinning? → **`raw_spinlock_t`**, with the kernel doc's caveats.
4. Is this read-mostly with high contention? → Don't pick a "lock flavor" — **remove contention** via per-CPU data, sharding, seqlock, or RCU. The lock primitive becomes irrelevant when contention is gone. (Contested per synthesis, but supported in aggregate by RCU/sharding literature.)

**Why this beats the naive "hot small cache → spinlock" intuition:**

- A hot cache lock holds for in-memory work only (your answer "A" — no blocking under the lock — confirms this), but **lock-holder preemption** still happens regardless of what your code does — the kernel can deschedule the holder thread mid-critical-section. When that happens, every spinning waiter wastes CPU until the OS gets back to scheduling your thread (potentially milliseconds). A mutex parks waiters cleanly.
- Modern user-space mutexes already adaptively spin a few times before parking. You get the cache-line-locality benefit when the hold is genuinely short, AND the bounded blocking when contention spikes.
- Spinlock scope tends to grow as the cache evolves (kernel doc warning). A mutex's sleep-safe semantics give you headroom; a spinlock locks you out of any future "hold this while reading the index file" addition.

**Targeted exceptions:** if benchmarking later proves sub-µs hold time, bounded thread count ≤ available CPUs, no blocking calls reachable from the critical section, AND measured contention low, a bounded spin (typically delivered by `pthread_spin_lock` or Windows `InitializeCriticalSectionAndSpinCount`) can be tested as an optimization. **Run `perf stat -e cache-misses,cache-references` against a representative workload before committing** — naive spinning shows up as elevated cache-miss rate and degraded p99 even when mean throughput looks fine (contested item; treat as advisory).

## Components

The "components" of a lock-choice decision aren't software modules — they're the **primitives, runtime conditions, and measurement instruments** the choice depends on. Identifying them lets you swap one without rewriting the rest.

### Lock primitives (the candidates)

| Primitive | Behavior on contention | When it wins |
|---|---|---|
| **`parking_lot::Mutex` / Windows `CRITICAL_SECTION` / pthread mutex (modern glibc)** | Adaptive: spin for N tries → park (futex/equivalent) | Default. ~1 byte state, single atomic uncontended; bounded under preemption. |
| **`std::mutex` (C++ pre-C++20 implementations)** | Implementation-defined; often wraps pthread mutex on POSIX, `CRITICAL_SECTION` on Windows | Fine in modern toolchains; benchmark before assuming `parking_lot` is the win. |
| **`pthread_spin_lock` / `std::sync::SpinMutex`-equivalent** | Pure busy-wait | Sub-µs critical section AND threads ≤ cores AND no preemption pressure AND no blocking under lock — all four required. |
| **`spinlock_t` (Linux kernel)** | Disables preemption + spins (non-RT); rt_mutex on PREEMPT_RT | Kernel atomic/interrupt context only. Under PREEMPT_RT `spinlock_t` *transparently becomes a sleeping lock* — code can't rely on bare-metal semantics. |
| **`raw_spinlock_t` (Linux kernel)** | Real raw spin; never transformed | "Real critical core code, low-level interrupt handling, places where disabling preemption or interrupts is required" (kernel `locktypes.html`). Not for ordinary cache code. |
| **Lock-avoidance: per-CPU data / sharded locks / `seqlock` / RCU** | No lock contention by construction | Read-mostly workloads where the contention itself, not the lock flavor, is the cost. |

### Runtime conditions (the inputs)

These determine which primitive applies — they are NOT fixed at code-write time and SHOULD be re-measured under realistic load:

- **Hold time distribution** — p50, p99, max. Sub-µs p99 is the threshold below which spinning *might* win; above it, mutex wins because the kernel will preempt the holder.
- **Contention** — how often does an acquirer find the lock held? Low contention removes the question (any primitive works); high contention favors mutex (parking is cheap; spinning is wasted CPU).
- **Thread oversubscription** — threads > available CPUs means waiters are scheduled candidates competing with holders. Spinlocks degrade pathologically here (matklad: 6–123 ms variance under heavy contention).
- **Sleep-reachability** — does any code path under the lock call `malloc` (which can sleep), I/O, log, allocate from a memory pool, etc.? If yes → mutex is the only correct choice; spinlocks are forbidden in kernel and dangerous in user space.
- **Kernel config** — PREEMPT_RT silently swaps `spinlock_t` for `rt_mutex`; assumptions about "spinlock = no sleep" become wrong without code changes.

### Measurement instruments (the verification)

A lock decision without measurement is a guess. The instruments:

- **`perf stat -e cache-misses,cache-references,task-clock`** — naive spinlock contention shows up as elevated cache-miss rate even when mean throughput looks fine.
- **`perf record -g` / `perf sched`** — lock-holder preemption events; correlate spinlock-waiter wakeup latency with holder reschedule.
- **Workload-representative microbench** — matklad-style: N threads contending K locks for fixed wall time, report mean + p99 + variance. Variance is the key metric; spinlocks blow it up.
- **Histogram of critical-section duration** — bpftrace / eBPF probe on the lock-acquire/release calls. Tells you which p99 bucket your workload lives in.

### Why this decomposition matters for the design

By naming primitives, conditions, and instruments separately, you can:

1. Change the primitive without changing the conditions you measured (e.g., swap `std::mutex` → `parking_lot::Mutex` if benchmarks show wins).
2. Change the conditions (e.g., reduce hold time by moving allocation outside the lock) without changing your primitive.
3. Re-validate when conditions drift (more threads, longer critical sections, kernel upgrade) without re-deriving the whole framework.

## Data Flow

This describes the **operational data flow** of a lock acquisition under each primitive — the path from "thread wants the lock" to "thread holds the lock" — so you can see exactly where a decision becomes wasted CPU vs. controlled blocking.

### Adaptive mutex (`parking_lot::Mutex` / Windows `CRITICAL_SECTION` / pthread mutex)

```
Thread T wants lock
  │
  ▼
[Atomic CAS: 0 → owner_id]   ← uncontended fast path: 1 atomic op
  │
  ├── ✅ Acquired → enter critical section
  │
  └── ❌ Already held
        │
        ▼
   [Adaptive spin: N retries with PAUSE/yield]   ← spin-then-park midpath
        │
        ├── ✅ Acquired during spin → enter critical section
        │
        └── ❌ Still held after N retries
              │
              ▼
         [Park: futex_wait / WaitForSingleObject / etc.]   ← OS deschedules waiter
              │
              ▼
         [Holder releases: futex_wake]   ← OS wakes one waiter
              │
              ▼
         [Re-attempt CAS] → enter critical section
```

**Key property:** waiters consume zero CPU after the spin window. Lock-holder preemption is bounded by the OS scheduler, not by `O(waiter count) × spin_quantum`.

### Bare spinlock (`pthread_spin_lock` / hand-rolled)

```
Thread T wants lock
  │
  ▼
[Atomic CAS: 0 → 1]
  │
  ├── ✅ Acquired → enter critical section
  │
  └── ❌ Already held
        │
        ▼
   [Loop: while (lock != 0) PAUSE; CAS again]   ← unbounded busy-wait
        │
        ▼
   [Eventually acquired]
```

**Failure mode:** if the holder is preempted by the OS scheduler mid-critical-section, every waiter spins until the holder is rescheduled — potentially milliseconds. Variance balloons (matklad: 6–123 ms). On a hot path under thread oversubscription, this is catastrophic.

### Linux kernel `spinlock_t` (non-RT)

```
Code in atomic/interrupt context wants lock
  │
  ▼
[preempt_disable()]   ← critical: cannot sleep
  │
  ▼
[Atomic CAS spin]
  │
  ▼
[Acquired] → enter critical section (no sleep, no schedule)
  │
  ▼
[unlock + preempt_enable()]
```

**On PREEMPT_RT kernels:** `spinlock_t` is silently remapped to `rt_mutex` — the same code path becomes a sleeping lock with priority inheritance. Code that called `local_irq_save()` thinking "I have the spinlock so I'm in atomic context" will be wrong.

### Lock-avoidance: per-CPU / RCU / sharded

```
Thread T does work
  │
  ▼
[CPU id = sched_getcpu() / __this_cpu_ptr()]
  │
  ▼
[Read/update per-CPU data — NO lock]   ← no contention possible by construction
  │
  ▼
[Optional: cross-CPU aggregation at read time, e.g., percpu_counter_sum]
```

Or for RCU:

```
Reader:                          Writer:
  rcu_read_lock()                  new_node = alloc()
  ptr = rcu_dereference(p)         old = p
  use(ptr)                         rcu_assign_pointer(p, new_node)
  rcu_read_unlock()                synchronize_rcu()  ← wait for readers
                                   free(old)
```

**Property:** readers never block, never atomic-op. Writers pay the synchronization cost once. For read-mostly hot caches this is a different decision-class — the lock primitive becomes irrelevant.

### Where the foo cache fits

Given your answer "A" (no blocking under the lock) and the topic ("hot small cache"):

- **Default path:** adaptive mutex → fast-path CAS → cache update → release. Expected path is the uncontended single-atomic case (~10ns on modern hardware).
- **Contended path:** adaptive mutex → spin retry → either acquires during spin (cheap) or parks waiter (correct under preemption).
- **Worst case:** holder preempted; all waiters parked, no spinning waste; OS wakes one when holder releases.

Compare with bare spinlock worst case: holder preempted; all waiters spinning at 100% CPU until OS reschedules holder; cache lines bouncing across cores; p99 latency dominated by scheduler quantum, not by your code.

The data flow makes the design conclusion concrete: there is no realistic operational path where a bare spinlock dominates an adaptive mutex for a user-space hot small cache.

## Error Handling

The "errors" in a lock-choice decision aren't exceptions — they're the **failure modes that turn a wrong choice into a production incident**, plus the safety-net design that contains the blast radius.

### Failure modes by primitive

| Primitive | Failure mode | Symptom | Containment |
|---|---|---|---|
| **Adaptive mutex** | Deadlock (lock-order violation) | Thread blocked indefinitely; `top` shows 0% CPU; gdb backtrace shows `pthread_mutex_lock` / `futex_wait`. | Document lock acquisition order; use `std::scoped_lock` for multi-mutex code; lock-order static-analysis (clang-tidy `bugprone-spuriously-wake-up`); periodic `pthread_mutex_timedlock` instead of bare `_lock` for hot paths. |
| **Adaptive mutex** | Priority inversion (low-pri holder, high-pri waiter) | Latency spike; high-pri thread blocked behind low-pri. | Use a mutex with priority inheritance (`pthread_mutexattr_setprotocol(PTHREAD_PRIO_INHERIT)`) on RT systems; rare in user space at non-RT priorities. |
| **Adaptive mutex** | Owner thread crashed mid-critical-section | All waiters parked forever. | `PTHREAD_MUTEX_ROBUST` returns `EOWNERDEAD` on next acquire so the recoverer can heal; consider per-process mutex if cross-process is unneeded. |
| **Bare spinlock** | Lock-holder preemption + thread oversubscription | All waiters spin at 100% CPU until OS reschedules holder; system load spikes; p99 collapses. | This IS the failure mode the design avoids by NOT picking a bare spinlock. If used anyway: pin holder threads to dedicated cores; use SCHED_FIFO; bound spin retries before parking. |
| **Bare spinlock** | Sleeping under the lock (e.g., page fault on cold memory) | Waiters spin while the kernel handles the holder's fault — milliseconds of waste. | Pre-touch all memory the critical section will read; never call into `malloc`, I/O, log, allocator under a spinlock. |
| **Linux `spinlock_t` (non-RT)** | Calling a sleeping function under the lock | Kernel BUG: scheduling while atomic. | Linux `lockdep` + `might_sleep()` / `might_resched()` annotations catch this in test builds; static analysis (Sparse, Coccinelle); code review. |
| **Linux `spinlock_t` (PREEMPT_RT)** | Code assumes "spinlock = atomic context" | Subtly wrong: lock now sleeps. | Use `raw_spinlock_t` only when you actually need atomic context; let `spinlock_t` mean "lock that may sleep on RT" by convention; lockdep validates. |
| **`raw_spinlock_t`** | Deadlock in interrupt context (lock held by interrupted code) | Kernel hard-lockup; watchdog reset. | Disable IRQs around lock acquisition (`spin_lock_irqsave`); kernel docs mandate this in interrupt-handling code. |
| **RCU** | Use-after-free if reader misses a grace period | Sporadic crash, reads from freed memory. | Use the RCU API correctly (`rcu_dereference`, `synchronize_rcu` before free); never hold a reference past `rcu_read_unlock`. |
| **Sharded locks** | Hash collision causes false sharing of "uncontended" shards | Unexpected contention spikes; performance sensitive to key distribution. | Use a high-quality hash (siphash, fxhash); benchmark with realistic key skew; cache-line-pad shards. |

### Cross-cutting safety nets

- **Lock timeout, not bare wait.** For diagnostic builds, prefer `pthread_mutex_timedlock` / `try_lock_for(1s)` and log on timeout. A blocked-forever thread is invisible; a "lock timeout exceeded 1 s" log entry is actionable.
- **`tracy::LockableBase` / `lockdep` / Visual Studio Concurrency Visualizer.** Lock-acquisition events become a profiler-visible timeline. Cheap; surfaces issues the moment they appear.
- **CI under thread sanitizer.** TSAN catches data races (which a wrong primitive will produce); also catches inverted-order acquisitions in tests that didn't trigger in single-threaded paths.
- **Production p99 monitoring on lock-acquire latency.** Treat it as a SLO, not a "we'll look if it spikes" metric. Mutex-park latency should sit ~scheduler-quantum (5–50 µs); spinlock contention shows up as p99 stretching to milliseconds.
- **Document why the choice was made.** A comment block at the lock declaration site naming the primitive, the operational conditions assumed, and the date of the most recent benchmark. When the next engineer wonders "why a mutex here, not a spinlock?", the answer is in-tree.
- **Re-validate when conditions drift.** Thread count change, kernel upgrade, hot-path refactor — any of these can invalidate the decision. The Components section's measurement instruments are the re-validation toolkit.

### What "wrong" looks like in production

A team that picked a spinlock for "performance" without measuring will see one of:

1. **CPU usage at 100% with throughput unchanged.** Spinning waiters burn cycles without making progress. Look for `task-clock` events without corresponding `cycles:u`.
2. **Tail-latency tail growing without mean change.** Mean is dominated by uncontended fast path; p99 is dominated by preempted-holder events. Mutex narrows the gap; spinlock widens it.
3. **System-wide latency interference.** Spinning threads steal CPU from unrelated processes; co-tenants on the box experience latency spikes whenever your spinlock contends.
4. **Failure to scale across cores.** Cache-line bouncing means adding cores adds contention, not throughput. The "hot small" cache becomes the bottleneck.

A team that picked an adaptive mutex from the start will see none of these — the failure modes that exist (deadlock, priority inversion) are well-trodden engineering problems with documented solutions, not architectural mistakes that require rewriting the cache.

## Testing

The testing strategy for a lock decision has three tiers — each catches a different class of regression. **Skip any tier and you ship a guess.**

### Tier 1 — Correctness (must pass before any perf claim)

Goal: prove the lock primitive doesn't introduce data races, deadlocks, or use-after-free.

| Test | Tool | What it catches |
|---|---|---|
| **TSAN run of the cache exerciser** | `clang -fsanitize=thread` / `gcc -fsanitize=thread` | Data races; missing synchronization; ABA-class memory ordering bugs. Run for ≥10 minutes under realistic concurrency. |
| **Helgrind / DRD** | Valgrind | Lock-order inversions; sleep-under-lock (Helgrind detects via instrumentation, not just races). |
| **Lock-order test** | Custom harness — multi-thread acquire mutex A then B vs B then A | Forces the deadlock if lock order isn't documented. Stress version uses random delays between acquisitions. |
| **Stress test under preemption** | Workload with `thread count > CPU count`; bind some threads to `nice 19`, some to `nice -10` | Surfaces lock-holder preemption pathologies (the spinlock failure mode). Healthy mutex shows bounded p99; broken spinlock shows pathological p99 stretch. |
| **Robustness test** | Send `SIGKILL` to a holder thread mid-critical-section; verify recovery | For `PTHREAD_MUTEX_ROBUST` mutexes: confirm `EOWNERDEAD` returned to next acquirer, recoverer rebuilds invariants. For non-robust: confirm the failure mode is documented and acceptable. |

### Tier 2 — Performance (only after Tier 1 is green)

Goal: validate that the chosen primitive meets the latency / throughput SLO under realistic load.

```
Workload-representative microbench (matklad-style):

  for primitive in [mutex, spinlock, ...]; do
    for thread_count in [1, 2, cores/2, cores, 2*cores]; do
      for hold_time_ns in [50, 500, 5000]; do
        run N=10 trials; report:
          - mean throughput (ops/sec)
          - p50 / p99 / p99.9 / max latency (ns)
          - CV (variance / mean)
          - cache-misses per op (perf stat)
      done
    done
  done
```

Pass criteria for the chosen primitive (adaptive mutex):

- **CV < 0.2 across all (thread_count, hold_time) combinations** — if variance balloons under oversubscription, the primitive is wrong (this is how you'd catch a regression that, say, swapped `parking_lot::Mutex` for a bare spinlock).
- **p99 ≤ 10× p50 in low-contention runs** — adaptive parking should bound this.
- **No throughput collapse at thread_count > cores** — mean ops/sec should degrade gracefully, not cliff.

Compare against bare spinlock to verify the decision (the "ablation"):

- Spinlock CV at high thread count should be visibly worse (matklad: 6–123 ms range under heavy contention is the canonical signature).
- Spinlock cache-miss rate should be visibly elevated.
- Spinlock p99 should pathologically stretch under preemption.

If the bench shows your adaptive mutex is NOT clearly better than the spinlock, the assumed runtime conditions don't match the workload — re-check the Components section's "Runtime conditions" inputs.

### Tier 3 — Production observability (the long-running test)

Goal: detect drift after deployment.

| Signal | Source | Alert threshold |
|---|---|---|
| **Lock-acquire p99 latency** | bpftrace / eBPF probe on `pthread_mutex_lock` enter/exit, or USDT probes if your mutex library exposes them | p99 > 10× baseline for 5 min → page; p99 > 100× → critical. |
| **`task-clock` vs `cycles:u` ratio per thread** | `perf stat -a -p <pid>` | Spinning threads burn task-clock without retiring instructions; ratio > 2× expected → investigate. |
| **Cache-miss rate per million cache ops** | Continuous `perf stat -e cache-misses,cache-references` | Spinlock contention shows up as elevated cache-miss rate even when throughput looks fine. Compare to baseline post-deploy. |
| **Critical-section duration histogram** | bpftrace `kprobe:lock_acquire` / `kretprobe:lock_release` (kernel) or USDT probes (user space) | Hold time crept above the threshold the design assumed → re-validate the lock choice. |

### Tier-3 test you actually run before tagging

```bash
# Minimal pre-deploy smoke
perf stat -e cache-misses,cache-references,task-clock,cycles:u \
  -- ./your-cache-bench --threads=$(nproc) --duration=60s

# Expected for adaptive mutex:
#   task-clock ≈ duration * threads (bounded blocking)
#   cycles:u   ≈ task-clock * 2 GHz (real work happening)
#   cache-misses / cache-references < 5%

# Spinlock contention warning signs:
#   task-clock >> cycles:u (spinning without retiring)
#   cache-misses / cache-references > 15% (cache-line bouncing)
```

### What this testing plan deliberately does NOT do

- **No "spinlock benchmarks faster than mutex on my laptop in single-threaded mode" test.** Single-threaded uncontended is the case where the primitive's choice is least decisive; emphasizing it produces wrong conclusions.
- **No "lock-free is always better" rabbit hole.** Lock-free cache designs (e.g., flat hash tables with linear-probe + atomic CAS per slot) are a different decision class; if the workload genuinely justifies them, they get a separate spec, not a footnote here.
- **No micro-optimization of the spin count.** Modern adaptive mutexes auto-tune. If you find yourself benchmarking spin_count=10 vs spin_count=50, you've fallen out of the decision framework — get back to "is this the right primitive?" first.

The testing strategy is the same shape as the decision: **measure under realistic conditions, treat variance as a first-class signal, and reject anecdotes (your own or someone else's) without a benchmark to back them.**

