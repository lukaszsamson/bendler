defmodule Bendler.Demos.MandelbrotReference do
  @moduledoc """
  Independent scalar Elixir implementation of the upstream fixed-point kernel.
  All arithmetic is explicitly reduced to U32, including negative coordinates.
  Like Bend, the recolour pass recomputes escape times rather than caching them.
  """
  import Bitwise

  @mask 0xFFFFFFFF
  @magic 2_654_435_761

  @spec checksum(0..18, 1..4096) :: non_neg_integer()
  def checksum(depth, iterations)
      when is_integer(depth) and depth in 0..18 and
             is_integer(iterations) and iterations in 1..4096 do
    count = 64 <<< depth

    histogram =
      Enum.reduce(0..(count - 1), :erlang.make_tuple(8, 0), fn id, hist ->
        bucket = bucket(pixel(id, iterations), iterations)
        put_elem(hist, bucket, elem(hist, bucket) + 1)
      end)

    {lut, _} =
      histogram
      |> Tuple.to_list()
      |> Enum.map_reduce(0, fn n, sum -> {div((sum + n) * 255, count), sum + n} end)

    table = List.to_tuple(lut)
    mix = Enum.reduce(lut, 0, fn value, acc -> u32(acc * @magic + value) end)

    recolour =
      Enum.reduce(0..(count - 1), 0, fn id, acc ->
        time = pixel(id, iterations)
        colour = elem(table, bucket(time, iterations))
        u32(acc + colour * u32(id * @magic + 1) + time)
      end)

    u32(mix * @magic + recolour)
  end

  @doc "Escape count at an upstream pixel index; zero iterations returns zero."
  @spec pixel(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def pixel(id, iterations) do
    cr = u32(div((id &&& 4095) * 768, 4096) - 512)
    ci = u32(div((id >>> 12) * 768, 4096) - 384)
    iterate(iterations, cr, ci, 0, 0, 0, 0)
  end

  defp iterate(0, _cr, _ci, _zr, _zi, _escaped, count), do: count

  defp iterate(n, cr, ci, zr, zi, escaped, count) do
    r2 = asr8(u32(zr * zr))
    i2 = asr8(u32(zi * zi))
    escaped = escaped ||| if(u32(r2 + i2) > 1024, do: 1, else: 0)
    nr = if escaped == 0, do: u32(r2 - i2 + cr), else: zr
    ni = if escaped == 0, do: u32(asr8(u32(2 * u32(zr * zi))) + ci), else: zi
    iterate(n - 1, cr, ci, nr, ni, escaped, count + if(escaped == 0, do: 1, else: 0))
  end

  defp bucket(time, iterations), do: min(div(time * 8, iterations), 7)
  defp u32(value), do: value &&& @mask
  defp asr8(value), do: value >>> 8 ||| if(value >>> 31 == 0, do: 0, else: 0xFF000000)
end
