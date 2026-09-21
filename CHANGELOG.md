# Changelog

## Unreleased

This release is not published yet. The current tree includes:

- Freeze the supported CPU Port API for 0.1.x in `docs/API.md`; separate
  experimental NIF/GPU work from the concise MVP release checklist.
- Verify the actual Hex tarball in an isolated consumer, including clean/rebuild
  and a compiler-free release, and run the check in CI.
- Preserve worker exit codes across a launcher poll/write EPIPE race instead of
  masking them as status 74. Add a deterministic regression, endpoint/errno
  diagnostics and cancellation/large-frame stress. The historical event/Murmur
  flakes remain unproven; this is not a claim that all status-74 failures are fixed.

- Experimental NIF emit streams: one outstanding typed event, sequence-checked
  acknowledgements, bounded admission, cooperative cancellation, native parked
  deadlines and the same lazy API as Port. Particle ticks and scalar events are
  benchmarked separately.
- Experimental typed NIF ask replies with owner/sequence checks, native response
  validation, bounded handler lifetime and CSV aggregation parity. Failed or
  abandoned asks freeze their module; typed application errors remain data.
- Correct native deadline handling: `enif_monotonic_time` is scheduler-only;
  admission translates deadlines into OS monotonic time before the Bend thread
  uses them. Event cancellation wakes parked IO without occupying a scheduler.

- Typed, per-call Port `ask` callbacks (tag 17), bounded off-owner handler
  execution, reply validation, same-worker direct reentry rejection and
  supervised failure recovery. CSV aggregation demonstrates native-owned
  input demand without transferring rows back to Elixir.
- Fix stream cleanup after owner replacement by retaining the original PID
  and monitor; reject generated `_stream` name collisions; preserve APNG
  repeat counts when correcting the number of frames after cancellation.

- Lazy streaming CSV demo over Port and experimental NIF, with arbitrary
  binary chunks, bounded records/batches, caller-owned cursors, differential
  tests and a NimbleCSV streaming benchmark. This uses incremental calls;
  Port `ask`/`emit` effects are separate features described below.
- A supervised CPU port backend for bounded pure Bend functions, with generated
  Elixir bindings, typed codecs, bounded admission, deadlines, telemetry, and
  launcher-owned worker termination.
- Boundary support for the documented scalar, string, byte-buffer, list, tuple,
  `Maybe`, `Result`, map, and same-file user-datatype subset, including codec
  validation and decoded-allocation budgets.
- Build isolation and reproducible artifact fingerprints, consumer-release
  support without Bend on `PATH`, and demos covering real port workloads.
- An experimental opt-in NIF backend with bounded asynchronous submission,
  caller monitoring, checked initialization, caller-side deadlines, and
  VM-lifetime pinning to keep live runtime code mapped. Graceful NIF unload is
  not implemented; the port backend remains the MVP default.
- Typed, bounded events out of Bend: a def answering `IO(T)` is an export, and
  a `~emit: E -> IO(Bool)` parameter is its typed event sink. A fourth foreign
  effect writes an EVENT frame (`BL_EVENT`, tag 16) and parks on the host's
  one-byte acknowledgement, so at most one event is outstanding and `False` is
  a typed, cooperative cancellation. Each such export gets a generated
  `_stream` function whose demand drives the acknowledgements. Port uses frames;
  experimental NIF uses resource-scoped, sequence-tagged messages.
- The ray tracer demo grew a camera fly-through (`fly`, `fly_gpu`) whose single
  call emits every frame as it finishes, and an animated-PNG writer that
  appends frames to the file while the render is still running.
- An experimental GPU-shaped port lane for programs using `!`; performance and
  availability depend on the kernel and installed platform toolchain.
- Public macOS 15 arm64 / Ubuntu 24.04 x86_64 CI with checksum-pinned Bend and
  LLVM, commit-pinned actions, ASan, release and isolated NIF checks. GPU builds
  retain a CPU-capable executable when no visible device produces a sidecar.

## Support status

The supported toolchain is Bend 2.0.20 with OTP 28. CI pins OTP 28.1,
Elixir 1.20.3 and LLVM 21.1.8. macOS 15 arm64 and Linux x86_64 / Ubuntu 24.04
have passed the checked-in CI workflow, including the isolated experimental
NIF probes. Windows is not supported.
