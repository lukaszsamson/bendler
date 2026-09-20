# End-to-end benchmark: Elixir reference vs the Bend port.
#
# Run it with:
#
#     MIX_ENV=test mix run demos/levenshtein/bench.exs
#
# It prints microseconds per pair for single calls and for batches,
# so the ~10 µs port hand-off can be read off the single-call rows
# and the parallel gain off the batch rows. Batch rows are warmed up
# and averaged: a batch of one pays the whole list transfer plus a
# parallel fork for a single comparison, so per-pair cost only
# collapses as the batch grows.

{:ok, _} = Bendler.Examples.LevPort.start_link([])
alias Bendler.Examples.LevPort
alias Bendler.Test.LevReference

short = {"kitten", "sitting"}

medium =
  {"the quick brown fox jumps over the lazy dog",
   "the quick brown fox jumps over the lazy cog"}

measure = fn label, ops, fun ->
  {us, _} = :timer.tc(fn -> Enum.each(1..ops, fn _ -> fun.() end) end)
  IO.puts("#{label}: #{Float.round(us / ops, 1)} µs/op (#{ops} ops)")
end

measure_batch = fn label, {a, b}, n, reps ->
  as = List.duplicate(a, n)
  bs = List.duplicate(b, n)
  # warmup: first list-heavy call pays heap growth, keep it out
  LevPort.batch_levenshtein(as, bs)

  {bus, _} = :timer.tc(fn -> Enum.each(1..reps, fn _ -> LevPort.batch_levenshtein(as, bs) end) end)

  {rus, _} =
    :timer.tc(fn ->
      Enum.each(1..reps, fn _ ->
        Enum.map(Enum.zip(as, bs), fn {x, y} -> LevReference.codepoint(x, y) end)
      end)
    end)

  IO.puts(
    "#{label} n=#{n}: bend batch #{Float.round(bus / reps / n, 1)} µs/pair, " <>
      "elixir loop #{Float.round(rus / reps / n, 1)} µs/pair"
  )
end

IO.puts("-- single pair, short strings --")
{s1, s2} = short
measure.("elixir reference", 200, fn -> LevReference.codepoint(s1, s2) end)
measure.("bend port       ", 200, fn -> LevPort.levenshtein(s1, s2) end)

IO.puts("-- single pair, 43-char strings --")
{m1, m2} = medium
measure.("elixir reference", 50, fn -> LevReference.codepoint(m1, m2) end)
measure.("bend port       ", 50, fn -> LevPort.levenshtein(m1, m2) end)

IO.puts("-- batch, short strings --")
for n <- [1, 8, 64], do: measure_batch.("short", short, n, 20)

IO.puts("-- batch, 43-char strings --")
for n <- [8, 64], do: measure_batch.("medium", medium, n, 10)
