# Murmur3 x86_32 in Bend

A port of Austin Appleby's MurmurHash3 x86_32 as in `preciz/murmur`, as a
Bendler demo: `murmur.bend` holds the algorithm, `lib/` the port module
and a reference copy for differential tests, `test/` the tests,
`bench.exs` the benchmark.

Two export shapes: `murmur3_x86_32/2` over a `List<U32>` of bytes, the
interim convention before Bendler had a bytes type, and `murmur3/2` over
the prelude's `B.Bytes`, which crosses as one buffer block. On 64 KB the
difference is 8.5 ms against 0.28 ms per hash (Elixir: 0.57 ms). Short
inputs are dominated by the ~10 µs port hand-off either way.
