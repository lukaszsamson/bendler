# ThumbHash: the Elixir reference vs the Bend port.
#
#     MIX_ENV=test mix run demos/thumbhash/bench.exs
#
# Image IO stays in Elixir; only the RGBA computation crosses. A 100x100
# image is 40 000 bytes each way as a list of U32, so the rows show the
# list-transfer cost beside the parallel DCT.
alias Bendler.Demos.{ThumbhashPort, ThumbhashReference}
{:ok, _} = ThumbhashPort.start_link([])

image = fn w, h ->
  :rand.seed(:exsss, {1, 2, 3})
  for _ <- 1..(w * h), into: <<>>, do: <<:rand.uniform(256) - 1, :rand.uniform(256) - 1, :rand.uniform(256) - 1, 255>>
end

measure = fn label, ops, fun ->
  fun.()
  {us, _} = :timer.tc(fn -> Enum.each(1..ops, fn _ -> fun.() end) end)
  IO.puts("#{String.pad_trailing(label, 34)} #{Float.round(us / ops / 1000, 2)} ms/op (#{ops} ops)")
end

for {w, h, ops} <- [{16, 16, 200}, {50, 50, 20}, {100, 100, 5}] do
  rgba = image.(w, h)
  measure.("elixir #{w}x#{h}", ops, fn -> ThumbhashReference.encode(w, h, rgba) end)
  measure.("bend   #{w}x#{h}", ops, fn -> ThumbhashPort.encode(w, h, rgba) end)
end

images = for _ <- 1..32, do: image.(32, 32)
measure.("elixir 32x32 x32 (sequential)", 5, fn -> Enum.map(images, &ThumbhashReference.encode(32, 32, &1)) end)
measure.("elixir 32x32 x32 (Task.async)", 5, fn -> Task.async_stream(images, &ThumbhashReference.encode(32, 32, &1)) |> Enum.to_list() end)
measure.("bend   32x32 x32 (batch)", 5, fn -> ThumbhashPort.encode_batch(32, 32, images) end)
