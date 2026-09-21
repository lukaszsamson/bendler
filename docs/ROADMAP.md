# Roadmap

Nothing here is a commitment. It records what the current design cannot do
and what would have to change first.

## Waiting on Bend upstream

- **A direct-call native library target.** `WONTFIX.txt` entry #813 is the
  hook: a compiler that can take roots which are never inlined, and emit per
  root a C entry plus a layout descriptor for its parameters and result,
  would remove the hand-off entirely. The work would then run on the calling
  scheduler thread instead of crossing a pipe or a wake-up. Everything in
  [DESIGN.md](DESIGN.md) is a workaround for its absence.
- **A cooperative runtime shutdown protocol.** Bend's worker threads never
  exit and there is no stop-and-join path, which is why a NIF runtime is
  pinned for the VM's lifetime. Stop flags, cancellation points, retained
  thread ids, joins, queue wake-ups, mapping cleanup and global-state reset
  are what safe NIF unload and upgrade, hard cancellation, and recoverable
  abandonment of a NIF ask all depend on.
- **`F64`.** Bend 2 has no double-precision float, so the boundary is single
  precision. A port that must match a double-precision reference bit for bit
  cannot, as the ThumbHash and raytracer demos both show.
- **Big naturals.** `Nat` is immediate up to 2^48-1 and larger values are a
  runtime error, so the codec rejects them. There is nothing to add until
  the runtime grows big naturals.
- **Deep right-spine forks under `!` on Metal.** A bang whose forks form a
  long right spine, about a thousand deep, dies with a machine stack
  overflow on the device while the CPU pool takes any depth. Reported as
  bendlang/bend#918. Balanced fork trees are the workaround the raytracer
  demo uses.
- **Operator sugar under `../` imports** (bendlang/bend#909). Until it
  works, a source can import the prelude only from its own directory, so
  the build writes a copy of `bendler.bend` next to every source using it.
- **`Bytes.from_list` with a known length in Base.** The prelude's version
  walks the list three times, so a caller that already knows the length
  packs the array itself; the raytracer demo does, and saved 17 ms on a
  640x480 render.

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
