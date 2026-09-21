# Murmur3 x86_32 in Bend

A port of Austin Appleby's MurmurHash3 x86_32 as in `preciz/murmur`, as a
Bendler demo: `murmur.bend` holds the algorithm, `lib/` the port module
and a reference copy for differential tests, `test/` the tests,
`bench.exs` the benchmark.

Two export shapes, kept side by side to measure the difference:
`murmur3_x86_32/2` takes a `List<U32>` of bytes, `murmur3/2` the prelude's
`B.Bytes`, which crosses as one buffer block. On 64 KB that is 8.5 ms
against 0.28 ms per hash (Elixir: 0.57 ms). Short inputs are dominated by
the port hand-off either way.
