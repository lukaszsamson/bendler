# Sorting and set operations

Tree-bitonic sorting over `List<U32>`, adapted from Bend's
[upstream network](https://github.com/bendlang/bend/blob/7561656155a4285c1e4ccfcb3505ab59524de973/bench/runtime/tree-bitonic/main.bend)
at revision `7561656155a4285c1e4ccfcb3505ab59524de973` (Apache-2.0).
The upstream `warp`/`flow` network is retained; list-to-tree conversion,
arbitrary-length padding/trimming, and set operations are new.

This follows the existing demos: Bend source, a generated Port module under
`lib/`, tests, and `bench.exs`. No new codec types, dependencies, GPU builds,
or changes to Bendler's runtime are required. Modules compile only in `MIX_ENV=test`.

## Use

```sh
mix test demos/sorting/test
MIX_ENV=test mix run demos/sorting/bench.exs
```

In a test-environment IEx session or application:

```elixir
alias Bendler.Demos.SortingPort
{:ok, supervisor} = Supervisor.start_link([{SortingPort, threads: 1}], strategy: :one_for_one)
SortingPort.sort([9, 1, 9, 0])         # [0, 1, 9, 9]
SortingPort.unique([9, 1, 9, 0])       # [0, 1, 9]
SortingPort.union([3, 1, 1], [2, 3])   # [1, 2, 3]
SortingPort.intersection([3, 1], [3])  # [3]
SortingPort.difference([3, 1], [3])    # [1]
Supervisor.stop(supervisor)
```

All inputs are ordinary unsorted lists of integers in `0..4_294_967_295`.
Sorting preserves duplicates. Set operations return **ascending unique lists**;
difference means left minus right. Empty and unequal-length lists are supported.
There are no user-defined comparison functions or arbitrary BEAM terms.

The list is padded to the next power of two with MAX_U32, sorted, and trimmed
to its original length. Trimming by length preserves genuine MAX_U32 values
and their multiplicity; removing every sentinel-valued element would be wrong.
The network sorts opposite-direction halves, then compare/exchanges and merges
them, exposing recursive fork pairs to the CPU runtime.

`unique` sorts and deduplicates. Union sorts the concatenation and deduplicates.
Intersection and difference sort/deduplicate both inputs in parallel and then
perform a fuel-bounded linear merge. Sorting uses O(N log² N) compare/exchange
work for padded size N. The straightforward list slicing during tree construction
also allocates intermediate lists; it is not a tuned in-place array sorter.
The sequential list codec and flattening do not become parallel just because
the sorting network has forks. Input lengths just over a power of two almost
double the network size. Frame limits are not a decoded-memory/work budget;
do not expose this experimental demo to unbounded untrusted workloads.

## Benchmark

```sh
SIZES=256,4096,32768 SAMPLES=5 THREADS=1,4,12 \
  SHAPES=random,sorted,reversed,duplicates \
  MIX_ENV=test mix run demos/sorting/bench.exs
```

Inputs are deterministic, prepared outside timing. Each case has a checked
warmup and five individually timed calls; all returned lists are verified
against Elixir outside timing. The script reports median/min/max, output count,
runtime versions and worker counts. Tiny operations can round to zero at
`:timer.tc`'s microsecond resolution; those rows are not reliable speedup ratios.
Build/startup time is excluded; Port measurements include encoding, handoff,
native work, reply decoding and generated return-type validation.

Sorting is compared to `Enum.sort/1` across random full-range U32s, pre-sorted,
reversed and duplicate-heavy (64 distinct possible keys) inputs. Set workloads
have two independently generated, overlapping lists of the largest requested
size, with values in `0..n-1`. The MapSet baseline includes construction of
both sets and **sorting its output**, giving the same observable result.
This is not a comparison against already-built MapSets.

`identity/1` sends the same list through the same binding without sorting.
It is a diagnostic round-trip baseline, not a precise number that can be
subtracted to recover native sorting time: allocation/GC patterns differ.

### Local results

Apple M2 Pro, macOS arm64, Elixir 1.20.3 / OTP 28, Bend 2.0.20,
Apple Clang 21.0.0. Five warm samples; median milliseconds:

| Random sort size | Enum.sort | Bend 1 worker | Bend 4 workers | Bend 12 workers |
|---|---:|---:|---:|---:|
| 256 | 0.006 | 0.107 | 5.065 | 10.030 |
| 4,096 | 0.227 | 2.293 | 15.786 | 22.547 |
| 32,768 | 2.212 | 29.601 | 44.091 | 49.980 |

For 32,768 elements, one-worker identity was 7.923 ms median (3.865–10.998 ms),
versus sorting at 29.601 ms (25.477–33.274 ms). The variation is material;
remeasure rather than treating these as stable per-element costs. Pre-sorted
32,768-element input took Enum 0.292 ms versus Bend/one-worker 28.204 ms;
the fixed network does not exploit pre-existing order as Enum does.

| Set operation, 32,768 inputs per side | MapSet + sorted output | Bend 1 | Bend 4 | Bend 12 |
|---|---:|---:|---:|---:|
| Union | 13.148 | 63.950 | 72.033 | 75.425 |
| Intersection | 11.115 | 62.918 | 67.730 | 68.426 |
| Left difference | 10.103 | 63.695 | 67.398 | 71.170 |

Outputs had 28,374 / 13,160 / 7,558 elements respectively.

**Finding: keep these operations in Elixir for the measured workloads.**
Unlike the compute-heavy Mandelbrot reduction, sorting sends a full list both
ways. Transport alone can exceed Enum's sorting cost, and extra Bend workers
make the fine-grained network slower here. Scheduling/synchronization and
allocation are plausible contributors, but this benchmark does not profile
their individual contributions. One worker is therefore the demo default.
This is evidence about this implementation, not a claim that parallel sorting
can never win or that every Bend sorting algorithm has these costs.

The useful next experiments are a fork-granularity cutoff, less allocation in
list-to-tree conversion, a packed U32 buffer type, and sorting data already
resident in Bend as part of a larger computation. GPU offload is not a switch
on this CPU binding and is not implemented or measured here.

## Correctness

Four ExUnit tests cover both one and four workers, deterministic random
full-range values, lengths around power-of-two boundaries, empty/singleton
lists, ascending/descending/all-equal inputs, duplicate MAX_U32s, all three set
operations against MapSet, duplicate-heavy randomized pairs, set identities,
and rejection of invalid U32 values. Benchmarks additionally compare every
timed result at the larger sizes. No checksum-only equality or floating-point
tolerance is used.

Validation after adding this demo: the complete suite passed 55 tests;
compilation with warnings-as-errors, explicit demo formatting checks, and
`mix credo 'demos/sorting/**/*.{ex,exs}' --strict` passed. The full suite
still emits the pre-existing unused `Bitwise` require warning in ThumbHash's
test file; no unrelated demo files were changed.
