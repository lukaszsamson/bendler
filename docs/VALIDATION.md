# Validation record

Observed 2026-09-20 on macOS arm64 (Apple M-series, 24 schedulers), Bend
2.0.20 at `~/.bend/bin/bend` (checkout `7561656…`), Elixir 1.21.0-dev on
OTP 28 (erts 16.4.0.1), Apple clang 21. A smoke test of compatibility and
behaviour, not a benchmark or a safety certification.

## Test suite

`mix test`: **46 tests, 0 failures** (19 core, 27 across the three demos), repeated runs with random seeds.
Coverage:

1. Signature parsing: exportable defs, skipped ones with reasons, trailing
   comments, multi-line signatures reported, `a.b`/`a_b` collision refused.
2. Codec round-trips for every type including nested lists; range checks;
   a list count past the binary refused; error frames carry a message.
3. NIF: generated functions with docs; every marshalled type; empty and
   nested lists through the native codec; a parallel call; Elixir-side
   argument checks; 16 callers at concurrency 4 all served, 32 callers of a
   slow def get a mix of results and `:busy`; a 150 ms deadline abandons a
   slow request, the runtime finishes it and later calls work; a `Nat`
   overflow freezes that module's runtime (`:dead`) while another NIF
   module keeps working.
4. Port: every type, nested lists, concurrent callers; with `max_queue: 1`
   and a 150 ms deadline: one in flight, one queued, the third `:busy`, the
   deadline stops the owner with `{:shutdown, :timeout}`, the queued caller
   gets `:exited`, the supervisor's replacement serves the next call; a
   well-framed but invalid request (wrong type, trailing bytes, unknown
   index) is answered with an error frame and the worker serves the next
   call; queued callers get `:exited` when the port dies.
5. The NIF refuses an invalid request on the calling thread with the
   reason text, before anything reaches the runtime.
6. A NIF request posted but never picked up before its deadline is
   withdrawn, and the loop parks cleanly afterwards and serves again.

## Bytes

`B.Bytes` round-trips through both backends: sums, reversal and indexing
on small binaries and on 100 KB of random bytes; a list where a binary is
declared is refused on the Elixir side. Benchmarks (`demos/*/bench.exs`):

| workload | List<U32> | Bytes | Elixir |
|---|---|---|---|
| Murmur3, 5 B | 11.8 µs | 8.9 µs | 0.1 µs |
| Murmur3, 64 KB | 8.5 ms | 0.28 ms | 0.57 ms |
| ThumbHash 100x100 | 10.8 ms | 5.8 ms | 26 ms |
| ThumbHash 32x32, batch of 32 | 16 ms | 9 ms | 18 ms (`Task.async_stream`) |

## Static checks

`mix credo --strict` runs the full default check set (69 checks) with a
120-column line limit and reports no issues; `mix dialyzer` with
`unmatched_returns`, `missing_return` and `extra_return` reports none;
`mix compile --warnings-as-errors` and `mix format --check-formatted`
pass.

## Build workflows

- `MIX_ENV=test mix bendler.clean` then `mix compile` rebuilt all four
  artifacts (the review's R1: previously it built none).
- A separate Mix application (`scratch/consumer`) with `{:bendler, path:
  "../.."}` and the `:bendler` compiler built exactly one artifact, its own
  `consumer_calc`, and `Consumer.Calc.add(20, 22)` returned 42 through the
  port. The dependency's own `priv/bendler/` still shows this repository's
  test artifacts because Mix symlinks a project's `priv/` into every
  environment's build; nothing from it is built by the consumer.

The line `bendler: stdout write failed` on stderr during the suite is the
port worker exiting after its owner closed the port on a deadline; `bend: a
Nat past the largest immediate 2^48-1` is the overflow test.

## Sanitizer

The port program was rebuilt from the test build directory with
`-fsanitize=address` and driven from Elixir with `nest([])`,
`nest([[], [1], []])`, `words("")`, `range(0, [])` and a frame whose list
count (100000) exceeds its bytes. All four calls answered correctly with
no sanitizer report; the lying count exited 65. This exercises the fix for
the empty-list type scanner that an independent review reproduced with ASan on the
previous version.

## Concurrency trace

Instrumenting the NIF transport (stderr prints on post, take, reply, done)
with 4 concurrent callers showed reply 6 overwritten by reply 7 before
caller 6 reacquired the mutex. After giving each call its own slot, five
rounds of 16 calls at concurrency 4 completed; the instrumentation was
removed.

## Release

`MIX_ENV=prod mix release` built `_build/prod/rel/bendler`. Running its
`eval` with `PATH=/usr/bin:/bin` (no `bend`) called
`Bendler.Examples.FibNif.fib(30, 0, 1)` → 832040 and, after
`FibPort.start_link/0`, `FibPort.words("a b")` → `["a", "b"]`. The build
is not invoked at runtime. Note that the release's `priv/bendler/` also
contained the test-only modules' artifacts, because Mix shares the
project's `priv/` across environments.

## Measurements

From `mix run scratch/bench.exs` (2000 warm calls averaged; one timed
`pow2(24)`), before the admission and deadline changes:

| call | NIF | port |
|---|---|---|
| `is_big(5)` | 10.3 µs | 9.7 µs |
| `fib(90, 0, 1)` | 14.6 µs | 12.1 µs |
| `range(1000, [])` | 69 µs | 65 µs |
| `pow2(24)` | 9 ms | 8 ms |

## Not validated

Linux; GPU programs; hostile worker output beyond the frame cap; memory
growth under sustained load; unload or upgrade of a NIF module (unsupported
by design); hard cancellation; more than one request in flight; concurrent
builds; per-environment artifacts.

## CSV and composite types (2026-09-20)

Final full suite: **65 tests passed**. Compilation with warnings-as-errors,
formatting of changed Elixir files, targeted strict Credo (10 files), Dialyzer
(zero errors) and documentation generation with warnings-as-errors passed.
The full test run still prints an existing unused `require Bitwise` warning
from the ThumbHash test file, which this change does not modify.

Added native Port and NIF coverage for 2–16-field tuples, explicitly nested
tuples, Maybe, Result, Bytes inside variants, empty nested lists and both
Result branches. Malformed arities, tags, missing payloads and trailing bytes
are rejected without poisoning the runtime. Result failures return data;
transport-error frames still raise and cannot appear inside composite values.

The CSV demo uses NimbleCSV 1.3.0 as an eager-parser oracle. It checks binary
preservation, CRLF, multiline quotes, escaped quotes, both header policies,
structured errors and recovery. Forty generated tables round-trip through
NimbleCSV's dumper, and all 781 length-0–4 inputs over quote/comma/CR/LF/a
agree on acceptance and successful values. The input wrapper caps input at
1 MiB; the raw generated function does not impose that demo-specific cap.

Commands: `mix test`; `mix credo 'lib/bendler/{sig,gen,codec}.ex'
test/composite_test.exs test/support/composite.ex 'demos/csv/**/*.{ex,exs}'
--strict`; `mix dialyzer`; `mix docs --warnings-as-errors`.

`MIX_ENV=test mix run demos/csv/check_asan.exs` passed 100 cycles against an
AddressSanitizer-instrumented external port, including empty composite lists,
nested options/Bytes, Result errors and malformed frames. Leak detection is
disabled because runtime teardown is not validated. This is not NIF sanitizer
coverage. A combined ASan/UBSan run stopped in generated runtime `root_done`
(`shim.c:1269`, zero-offset pointer arithmetic on null); the Bend runtime is
therefore not claimed UBSan-clean. No workaround patches were applied to it.

Five-sample CPU benchmark results and limitations are in
`demos/csv/README.md`. NimbleCSV won every measured case. No Linux, streaming,
GPU or arbitrary-user-datatype claim is made by this demo.

## F32, Char and Map (2026-09-20)

Full suite: **70 tests passed**; warnings-as-errors, format, credo
(strict), dialyzer and `mix docs --warnings-as-errors` clean.

| check | port | NIF |
|---|---|---|
| `half(3.0)`, `half(0.1)` rounds to single, `-1.0e-45` underflows to `-0.0` | yes | yes |
| `1.0/0.0`, `-1.0/0.0`, `0.0/0.0` come back as `:infinity`, `:neg_infinity`, `:nan`; the atoms go in too | yes | yes |
| `upper(?a)`, an astral code point, `String.to_list` as a charlist, a charlist back to a String | yes | yes |
| `tally` builds a `Map<&2, U32>` in Bend; `total` consumes one; `scale` round-trips `Map<F32>`; `Map<List<B.Bytes>>` with an empty key | yes | yes |
| 4096 keys through the trie | yes | yes |
| native validator refuses a surrogate or out-of-range Char and a short F32 before dispatch; the worker keeps serving | yes | yes |

Codec unit tests: a double past the single range, an integer or a string
as `F32` raise; negative, surrogate and past-range Chars raise; a reply
Char is range-checked on the host; a map with atom keys or a pair list in
place of a map raise; the pair list becomes a map in `check/3`.
