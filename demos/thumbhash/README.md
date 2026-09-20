# ThumbHash in Bend

A port of [thumbhash-ex](https://github.com/Hentioe/thumbhash-ex)'s
encoder (Evan Wallace's ThumbHash) as a Bendler demo: `thumbhash.bend`
holds the algorithm, `lib/` the port module and a verbatim copy of the
Elixir reference for differential tests, `test/` the tests, `bench.exs`
the benchmark.

Image IO stays in Elixir. Only the RGBA computation crosses: the pixels
as the prelude's `B.Bytes` (one buffer block; `thumbhash/3` still takes a
`List<U32>` for comparison) and the hash comes back as a list of bytes.
Floats stay inside Bend as `F32`.

What the port taught:

- **F32 versus doubles.** The reference computes in Elixir doubles and
  Bend in 32-bit floats. Most hashes agree byte for byte; a coefficient on
  a quantisation boundary can land one level off. The tests accept a
  one-step difference and require most cases to be exact. A first-class
  `F64` or a documented precision policy is what a real port would need.
- **The reference has a latent bug**: it encodes the alpha channel without
  passing `w` and `h`, so any image with transparency crashes. The copy
  here fixes that, following the original JavaScript.
- **Bend shapes the code**: no `match` on a computed value (every `if` is
  a helper def taking a `Bool`), no destructuring a call result, callees
  above callers, no mutual recursion (row chunking became a fold with a
  state tuple, the coefficient walk a generate-then-filter), and the
  shrinking argument first in every recursive def.
- **Bytes as a list cost more than the DCT** at 100x100: 10.8 ms as a
  `List<U32>` against 5.8 ms as `Bytes`. A batch of 32 small images lost
  to `Task.async_stream` as lists and wins as `Bytes` (9 ms vs 18 ms).
  See `bench.exs`.
