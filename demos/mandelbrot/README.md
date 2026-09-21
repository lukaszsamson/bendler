# Parallel Mandelbrot checksum

A CPU numeric kernel adapted from Bend's
[runtime benchmark](https://github.com/bendlang/bend/blob/7561656155a4285c1e4ccfcb3505ab59524de973/bench/runtime/mandelbrot/main.bend)
(Apache-2.0). The Bend arithmetic and checksum algorithm are unchanged.
It computes escape times, reduces an eight-bin histogram, builds a CDF colour
table, then recomputes/recolours pixels and reduces a position-weighted checksum.
The recursive `a b = ... ...` forks expose parallel work to Bend's CPU pool.

This follows the other demos: Bend source, `lib/` Port and Elixir reference,
`test/` differential tests, and end-to-end `bench.exs`. The existing Mix wildcard
discovery includes it only in the test environment; no library dependencies or
core compiler/codec changes are needed.

## Run

```sh
mix test demos/mandelbrot/test
MIX_ENV=test mix run demos/mandelbrot/bench.exs
```

In a test-environment application or IEx session:

```elixir
alias Bendler.Demos.MandelbrotPort
{:ok, supervisor} = Supervisor.start_link([{MandelbrotPort, threads: 4}], strategy: :one_for_one)
MandelbrotPort.checksum(2, 7) # 887240761
Supervisor.stop(supervisor)
```

`checksum(depth, iterations)` accepts depth 0..18 and iterations 1..4096.
It covers the **first `64 * 2^depth` pixels of a fixed 4096×4096 viewport**,
not a smaller resized image. The default benchmark depths 2, 8 and 12 are
upper-viewport strips, not representative full fractal renders. The algorithm
still executes its fixed iteration budget after escape. Depth 18 is the full
viewport; `(18, 51)` must return `3101455856` and is covered by a test.

Only two Nat arguments and a U32 result cross the boundary. This measures
compute-heavy reduction, not pixel-buffer transfer or image rendering. The
generated low-level `rend/2` and `pix/2` exports remain available for testing;
use the bounds-checked `checksum/2` for normal calls. They do not themselves
enforce the wrapper's workload bounds.

## Benchmark methodology

```sh
DEPTHS=2,8,12 ITERATIONS=31 SAMPLES=5 THREADS=1,4,12 \
  MIX_ENV=test mix run demos/mandelbrot/bench.exs

# Optional dependencies installed separately; never added to Bendler mix.exs:
DEPTHS=2,8 SAMPLES=3 elixir demos/mandelbrot/bench_nx.exs
NX_COMPILER=exla elixir demos/mandelbrot/bench_nx.exs
```

Both scripts accept `DEPTHS`, `ITERATIONS` and `SAMPLES`. Run them separately,
without other benchmarks/builds competing for CPU. `bench.exs` accepts `THREADS`.
It warms each case, verifies every result, and reports median/min/max wall time
plus the first call separately. Port timing includes request encoding, handoff,
native computation and reply decoding; startup/build time is not in warm samples.
The first Port call can still pay asynchronous runtime initialization.

The Nx script pins Nx/EXLA 0.10.0, forces EXLA's **host CPU**, generates coordinates
inside the numerical kernel, and includes scalar readback (`Nx.to_number`) so it
does not merely time asynchronous dispatch. First-call timing includes JIT when
that shape is not already cached; warm measurements exclude compilation.
It verifies an upstream known answer, full-viewport pixel samples, and the
Elixir reference checksum for every measured workload.

Nx retains escape times between histogram and recolour passes, whereas the
upstream Bend and Elixir algorithms compute them twice. This is a same-result
comparison of implementations, **not identical instruction counts**. Nx's
[BinaryBackend](https://hexdocs.pm/nx/0.10.0/Nx.BinaryBackend.html) is pure Elixir;
its numbers must not be presented as optimized Nx CPU performance. The EXLA
comparison is the relevant optimized baseline. Neither has GPU enabled.

On this machine Apple Clang 21 rejected specializations in XLA 0.9.1's bundled
headers. The optional EXLA install succeeded with this targeted compatibility
flag (not required by the Bend build):

```sh
CFLAGS=-Wno-invalid-specialization EXLA_CPU_ONLY=true NX_COMPILER=exla \
  elixir demos/mandelbrot/bench_nx.exs
```

The pinned optional dependencies also emit warnings under Elixir 1.20.3; those
are separate from compilation of the demo. First installation needs network
access and downloads a native XLA archive. Record resolved dependency versions
when comparing another machine; only the top-level versions are pinned here.

## Measured results

Local run: Apple M2 Pro, 12 online schedulers, macOS arm64, Elixir 1.20.3,
OTP 28 (ERTS 16.4.0.1), Bend 2.0.20, Apple Clang 21.0.0. Nx/EXLA 0.10.0
with XLA 0.9.1, host CPU defaults. Five warm samples, median milliseconds,
31 iterations per pixel, scripts run separately after dependency builds finished:

| Implementation | 256 pixels | 16,384 pixels | 262,144 pixels |
|---|---:|---:|---:|
| Scalar Elixir, two passes | 0.624 | 35.433 | 568.686 |
| Bend Port, 1 thread | 0.092 | 3.692 | 59.426 |
| Bend Port, 4 threads | 0.205 | 1.120 | 15.182 |
| Bend Port, 12 threads | 0.455 | 0.757 | 7.878 |
| Nx/EXLA host CPU, cached escape times | 0.078 | 1.941 | 8.426 |

Checksums respectively: `30650296`, `3097307340`, `481032205`.
At 262,144 pixels the 12-thread Port ranged from 7.731 to 8.692 ms;
EXLA ranged from 8.070 to 9.832 ms. Those ranges overlap: treat these
implementations as comparable here, **not evidence of a general win over Nx**.
Bend scaled about 7.5x from one to twelve threads and was about 72x faster
than this scalar Elixir reference on the largest measured strip. On 256 pixels
more Bend workers hurt; choose batch size/work granularity before thread count.
EXLA's first calls were 43.341 / 68.616 / 58.854 ms, separate from warm timings.

A separate full-viewport `(18, 51)` Bend call, twelve workers, returned the
upstream `3101455856` checksum in 903.548 ms (single first-call observation,
not a warm median and not part of the above comparison). The test suite
also verifies this known answer with four workers, alongside one- and
four-thread checksums, sampled pixel escape counts, invalid wrapper inputs
and the full upstream case.

The BinaryBackend is dramatically slower on this workload (the 262,144-pixel
baseline takes tens of seconds per sample); use smaller `DEPTHS` for a quick
correctness check. It is deliberately not used for the headline speedup.

## Types and GPU findings

No new base types were necessary: the upstream kernel deliberately uses signed
8.8 fixed-point values represented by wrapping U32 operations. The independent
Elixir and Nx implementations reproduce those shifts/overflows exactly. There
is no floating-point tolerance hiding incorrect results.

No GPU build support was added. The imported upstream `main` contains a `!`
call, but Bendler reaches `rend` through its generated CPU dispatcher; the
generated C has `BANGS 0` and the worker runs with `--gpu off`. Merely changing
a command-line flag would not offload this binding. Offloading this kernel would
need an offload-marked dispatch root, not a different command-line flag.
