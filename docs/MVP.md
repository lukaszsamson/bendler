# MVP release checklist

Bendler is feature-complete for an early-adopter **CPU Port binding generator**.
It runs bounded Bend computations under Elixir supervision, including sequential
typed emit/ask effects. The supported 0.1.x surface is frozen in [API.md](API.md).
NIF and GPU lanes are experiments, not part of that stability promise.

Do not expand this checklist with speculative features. New work should fix a
reliability problem or satisfy an external consumer's demonstrated need.

## Release gates

- [x] Generated bindings, documented type subset and error semantics.
- [x] Supervised Port lifecycle, bounded queue, total deadlines, caller monitoring,
      launcher-owned process-group termination and worker reaping.
- [x] Codec validation/allocation budgets, differential tests, fuzz cases and Port ASan.
- [x] Atomic builds, app/environment/target isolation, clean/rebuild and compiler-free releases.
- [x] License, package metadata, changelog, formatting, Credo, Dialyzer and ExDoc.
- [x] Pinned macOS arm64 / Linux x86_64 CI; see VALIDATION.md for revision-specific evidence.
- [x] Build the real Hex tarball, unpack it outside the checkout and test a fresh
      consumer, clean/rebuild and a compiler-free release. Repro: `sh test/package_smoke.sh`.
- [x] Define the stable API and separate experimental and internal interfaces.
- [ ] Close the historical unexplained Port status-74 investigation. A deterministic
      launcher exit-status masking race has a fix and regression test; this does
      **not** establish the cause of the earlier event/Murmur failures.
- [ ] Run the updated CI workflow on the release commit, review its results,
      then explicitly approve tagging/publishing. Nothing here publishes to Hex.

The transport investigation and exact validation evidence live in
[VALIDATION.md](VALIDATION.md). A green stress run is evidence, not proof that
an unreproduced failure is fixed.

## What is included

The CPU Port contract includes generated pure and sequential IO calls, typed
ask handlers, demand-driven emit streams, supported Base/composite/user types,
Mix build/clean tasks, supervision and documented telemetry. See
[API.md](API.md), [CONTRACTS.md](CONTRACTS.md) and [TYPES.md](TYPES.md).

One request executes per worker. Applications choose their supervision and
worker topology. Callers should use finite deadlines and bound their inputs;
codec budgets are not an OS memory limit and cannot bound arbitrary Bend work.

## Existing demos are sufficient

| Workload | Question answered |
|---|---|
| Batched Levenshtein | Can independent CPU work amortize the boundary? |
| Murmur3 | What do packed bytes save compared with lists? |
| ThumbHash | Do real numeric/image kernels justify a binding? |
| Mandelbrot | How does CPU parallelism compare with Elixir and Nx/EXLA? |
| Sorting/set operations | When should the work stay in Elixir? |
| CSV, streaming CSV, ask-driven aggregation | What are the parser, buffering and callback costs? |
| Raytrace/fly-through | Can user datatypes and backpressured output support a larger workload? |
| Particle ticks | When does experimental NIF event delivery help? |

Each demo owns its benchmark method, results and limitations. Do not copy
historical timings into this checklist. The next useful validation is a small
external consumer, preferably reusing an existing kernel, not another transport
feature or synthetic demo.

## Non-goals for 0.1.x

- Production NIF lifecycle, safe unload/upgrade, hard cancellation or recoverable
  abandonment of an arbitrary NIF ask continuation.
- Arbitrary BEAM terms, ETS access from native code, linked-in drivers or direct
  compiler-generated native function exports.
- Multiple native requests in flight, combined ask/emit channels, configurable
  callback handler deadlines or windowed event acknowledgements.
- Broad new type coverage, an inline sigil, precompiled distribution, a GPU
  performance promise or a compiler fork.

These are parked possibilities, not commitments. NIF findings remain in
[NIF_ROADMAP.md](NIF_ROADMAP.md) and [BEAM_API.md](BEAM_API.md).
The original investigation and completed implementation history remain in
RESEARCH.md, REVIEW.md, TRACK2.md and the chronological validation record.
