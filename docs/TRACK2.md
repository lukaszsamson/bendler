# Track 2 execution plan

Historical execution record. Current release gates and the supported API are
in MVP.md and API.md; the plan below is retained as implementation background.

The release promise remains a reliable CPU Port binding for bounded pure
functions. NIF lifecycle support and GPU builds are not implied by this work.

Work is ordered by the dependency it closes, with independent implementation
and tests running in parallel:

1. Diagnose the sanitizer failure. Keep instrumentation enabled, preserve
   production artifacts, prove a narrowly scoped compatibility adjustment.
2. Add a launcher that owns, terminates and reaps the worker after owner
   death/deadline, including a worker that ignores TERM and never does IO.
3. Isolate build and runtime artifacts by environment and target; serialize
   conflicting builds and exercise fresh/cache/concurrent build paths.
4. Add decoded allocation budgets and deterministic property/fuzz coverage
   for both transports; extend ASan checks and wire them into pinned CI.
5. Observe sustained overload and worker RSS, without conflating a decoded
   input budget with an OS process-memory limit or arbitrary output bound.
6. Publish signature/error/Unicode/platform contracts and call telemetry;
   remeasure end-to-end hand-off overhead after the launcher changes.

Completion is recorded in MVP.md and VALIDATION.md only after integrated
tests have run. Local macOS results do not establish Linux support; CI must
run there. External upstream issue filing, publishing and GPU expansion
remain separate actions.
