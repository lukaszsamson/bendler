# Roadmap

Nothing here is a commitment. It records what the current design cannot do
and what would have to change first.

## Waiting on Bend upstream

- **A direct-call native library target.** `WONTFIX.txt` entry #813 is the
  hook: a compiler that can take roots which are never inlined, and emit per
  root a C entry plus a layout descriptor for its parameters and result,
  could enable a direct-call backend without the runtime-thread hand-off.
  Long computations would still need dirty scheduling, and marshalling and
  native memory safety would remain concerns. Upstream tracks this as
  [planned, not scheduled](https://github.com/bendlang/bend/issues/813#issuecomment-5738681560).
- **A cooperative runtime shutdown protocol.** Bend's worker threads never
  exit and there is no stop-and-join path, which is why a NIF runtime is
  pinned for the VM's lifetime. Stop flags, cancellation points, retained
  thread ids, joins, queue wake-ups, mapping cleanup and global-state reset
  are needed for safe NIF unload and upgrade. Recoverable abandonment of an
  ask additionally needs safe request-level unwinding. A cooperative shutdown
  protocol alone would not guarantee hard interruption of arbitrary work.
- **`F64`.** The supported Bend 2.0.25 toolchain has no double-precision float, so the boundary is single
  precision. A port that must match a double-precision reference bit for bit
  cannot, as the ThumbHash and raytracer demos both show.
- **Big naturals.** `Nat` is immediate up to 2^48-1 and larger values are a
  runtime error, so the codec rejects them. There is nothing to add until
  the runtime grows big naturals.

## Bend toolchain compatibility

The pinned Bend 2.0.25 includes these upstream fixes:

- [#909](https://github.com/bendlang/bend/issues/909#issuecomment-5754216536),
  operator sugar involving module-local calls under parent-directory imports,
  was fixed in Bend 2.0.22.
- [#918](https://github.com/bendlang/bend/issues/918#issuecomment-5754216072),
  deep right-spine forks overflowing the Metal device stack, was fixed in
  Bend 2.0.23. The raytracer uses balanced forks, which remain useful for
  performance.

Adopting a newer toolchain requires validating the generated-runtime patches,
both transports and GPU builds, then updating the version gate and CI archive
checksums. The issues above are not unresolved upstream blockers.
The build copies the prelude beside sources to resolve their literal
`import ./bendler.bend as B`; this is not a general restriction on `../` imports.

## Deferred by choice

These are parked possibilities, not promises.

- Multiple requests in flight per module. The codec cursor is global, so
  overlapping requests would need per-request cursors and reply ids.
- An export with both an ask and an emit channel.
- Windowed acknowledgements instead of one outstanding event.
- A configurable handler deadline, instead of the fixed five seconds.
- Precompiled artifacts in the published package.
- An inline `~B` sigil for Bend source.
- Bend's Window and Audio effects, which need their own lifecycle and
  transport design, and X11 and ALSA development libraries on Linux.
- Windows.
