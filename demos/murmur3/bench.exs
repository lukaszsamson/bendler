# End-to-end benchmark: Elixir reference vs the Bend port.
#
# Run it with:
#
#     MIX_ENV=test mix run demos/murmur3/bench.exs
#
# Murmur3 is cheap per byte, so single short hashes are hand-off
# dominated; watch the per-hash cost collapse in the batch rows and
# the transfer cost of the interim `List<U32>` bytes convention in
# the 64KB row (a first-class binary, track 3, would skip the
# per-byte list cells).

{:ok, _} = Bendler.Examples.MurmurPort.start_link([])
alias Bendler.Examples.MurmurPort
alias Bendler.Test.MurmurReference

hash_bin = fn bin, seed -> MurmurPort.murmur3_x86_32(:binary.bin_to_list(bin), seed) end

short = "01234"
medium = "the quick brown fox jumps over the lazy dog"
kb1 = String.duplicate("abcdefgh", 128)
kb64 = String.duplicate("abcdefgh", 8192)

measure = fn label, ops, fun ->
  {us, _} = :timer.tc(fn -> Enum.each(1..ops, fn _ -> fun.() end) end)
  IO.puts("#{label}: #{Float.round(us / ops, 1)} µs/op (#{ops} ops)")
end

measure_batch = fn label, bins, seed, reps ->
  datas = Enum.map(bins, &:binary.bin_to_list/1)
  # warmup: first list-heavy call pays heap growth, keep it out
  MurmurPort.batch_murmur3(datas, seed)

  {bus, _} = :timer.tc(fn -> Enum.each(1..reps, fn _ -> MurmurPort.batch_murmur3(datas, seed) end) end)

  {rus, _} =
    :timer.tc(fn ->
      Enum.each(1..reps, fn _ -> Enum.map(bins, &MurmurReference.hash_x86_32(&1, seed)) end)
    end)

  n = length(bins)

  IO.puts(
    "#{label} n=#{n}: bend batch #{Float.round(bus / reps / n, 1)} µs/hash, " <>
      "elixir loop #{Float.round(rus / reps / n, 1)} µs/hash"
  )
end

IO.puts("-- single hash --")
# warmup: first calls pay worker heap growth, keep them out
MurmurPort.murmur3_x86_32(:binary.bin_to_list(short), 0)
measure.("short (5B) elixir", 500, fn -> MurmurReference.hash_x86_32(short, 0) end)
measure.("short (5B) bend  ", 500, fn -> hash_bin.(short, 0) end)
measure.("medium (43B) elixir", 200, fn -> MurmurReference.hash_x86_32(medium, 0) end)
measure.("medium (43B) bend  ", 200, fn -> hash_bin.(medium, 0) end)
measure.("1KB elixir", 50, fn -> MurmurReference.hash_x86_32(kb1, 0) end)
measure.("1KB bend  ", 50, fn -> hash_bin.(kb1, 0) end)
measure.("64KB elixir", 10, fn -> MurmurReference.hash_x86_32(kb64, 0) end)
measure.("64KB bend  ", 10, fn -> hash_bin.(kb64, 0) end)

IO.puts("-- batch, one seed --")
measure_batch.("short", List.duplicate(short, 64), 0, 20)
measure_batch.("medium", List.duplicate(medium, 64), 0, 20)
measure_batch.("medium", Enum.map(0..63, fn i -> "input-#{i}-#{medium}" end), 0, 10)
measure_batch.("1KB", List.duplicate(kb1, 16), 0, 5)

IO.puts("")
IO.puts("--- Bytes instead of List<U32> (the same hash, a buffer block each way)")
for {label, bin} <- [{"5 B", "abcde"}, {"64 B", :crypto.strong_rand_bytes(64)}, {"64 KB", :crypto.strong_rand_bytes(65_536)}] do
  MurmurPort.hash(bin, 0)
  ops = if byte_size(bin) > 1000, do: 20, else: 2000
  {lus, _} = :timer.tc(fn -> Enum.each(1..ops, fn _ -> MurmurPort.murmur3_x86_32(:binary.bin_to_list(bin), 0) end) end)
  {bus, _} = :timer.tc(fn -> Enum.each(1..ops, fn _ -> MurmurPort.hash(bin, 0) end) end)
  IO.puts("#{label}: list #{Float.round(lus / ops, 1)} µs, bytes #{Float.round(bus / ops, 1)} µs per hash")
end
