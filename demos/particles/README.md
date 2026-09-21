# Particle ticks: Port versus experimental NIF events

One native invocation evolves a balanced tree of independent 2D damped
oscillators, emitting `{tick, [{x, y}, ...]}` after each pure parallel step.
Particle state stays inside Bend. A snapshot is acknowledged only when the
Elixir consumer requests the next element. The stream ends with `{:done, ticks}`.

This is a transport/streaming demonstration, **not n-body physics**, a realtime
simulation framework or a GPU benchmark. It uses F32 explicit Euler updates
in a harmonic potential; two Bend CPU workers process a balanced fork tree.
Use small finite positive timesteps. Large timesteps can be unstable.

```elixir
alias Bendler.Demos.{Particles, ParticlesNif}
ParticlesNif.simulate_stream(Particles.cloud(16), 180, 0.03)
|> Particles.save_svg("/tmp/particles.svg")
```

The writer appends snapshots as SVG dots without retaining the entire stream.
The result shows trajectories colored by tick. It is a file, not a web server.
The equivalent `ParticlesPort` module needs to be started under a supervisor.

```sh
BACKEND=nif OUTPUT=/tmp/particles.svg MIX_ENV=test mix run demos/particles/render.exs
BACKEND=port OUTPUT=/tmp/particles-port.svg MIX_ENV=test mix run demos/particles/render.exs
N=64 TICKS=2000 SAMPLES=5 MIX_ENV=test mix run demos/particles/bench.exs
```

## What NIF events add

- Same generated `_stream` API, typed values and terminal result as Port.
- One outstanding event with a per-request sequence number. Stale/duplicate
  acknowledgements cannot accidentally advance a future event.
- `enif_send` from the runtime thread, independent message environments, and
  a short acknowledgement NIF that wakes Bend's IO loop. No scheduler waits
  for an acknowledgement; native computation still uses Bend's own pool.
- A finite deadline expires even while the consumer is paused at an event.
- Early halt, consumer failure and caller death suppress future delivery and
  wake a parked emit to answer false. Cancellation is cooperative: the request
  keeps its admission slot until the def returns, even after the Elixir stream
  has returned. Unlike Port, the runtime cannot be forcibly terminated safely.

The callback effects must stay on the sequential IO spine; concurrent emits
through `IO.fork` are unsupported. Combined ask/emit exports,
windowed acknowledgements, multiple executing requests, GPU execution and safe
runtime unload are not implemented. All existing experimental NIF hazards apply;
Port remains the default and the isolation boundary for untrusted work.

## Measurements

Apple M2 Pro, macOS arm64, Bend 2.0.20, Elixir 1.20.3 / OTP 28. Five warmed
samples; 2,000 events; two Bend CPU workers. Timings include encoding, transport,
decoding and an Elixir checksum reduction, but exclude file output. Both backends
must produce identical event counts, checksums and final results.

| Workload | Port total | NIF total | Port µs/event | NIF µs/event |
|---|---:|---:|---:|---:|
| Scalar pulse, minimal computation | 40.979 ms | 22.991 ms | 20.49 | 11.50 |
| 64-particle snapshots | 491.786 ms | 486.104 ms | 245.89 | 243.05 |

| Median latency | Port | NIF |
|---|---:|---:|
| First scalar event | 41 µs | 29 µs |
| First particle snapshot | 330 µs | 368 µs |
| Scalar cancellation plus next positions call | 345 µs | 287 µs |
| Particle cancellation plus next positions call | 260 µs | 288 µs |

NIF reduced scalar-event time by about 44%. The particle difference is only
about 1% and does not establish a practical advantage. Cancellation timings
include a subsequent positions call as a completion barrier: they are **not**
measurements of the transport round trip alone. No scheduler-jitter, peak-RSS
or long-duration soak result is claimed. One-outstanding backpressure was
sufficient here; the results do not justify a windowed protocol yet.

## Validation

`test/nif_events_test.exs` covers ordering, typed scalar/tuple/datatype events,
plain calls, paused consumers, caller death, cancellation races, bounded
admission, stale acknowledgements, native deadlines and fatal-module isolation.
This demo checks Port/NIF F32 equality, one-step integration against an analytic
case, and incremental SVG output. See `docs/VALIDATION.md` for the complete
check results and remaining limitations.
