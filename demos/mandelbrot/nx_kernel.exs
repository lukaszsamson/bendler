defmodule MandelbrotNx do
  @moduledoc false
  import Nx.Defn

  defn render(iterations, opts \\ []) do
    opts = keyword!(opts, count: 256)
    checksum(Nx.iota({opts[:count]}, type: :u32), iterations)
  end

  # Tensor version of the same U32 / signed 8.8 arithmetic. Keep escape
  # times between histogram and recolour passes (unlike upstream Bend).
  defn pixels(ids, iterations) do
    cr = Nx.quotient(Nx.bitwise_and(ids, 4095) * 768, 4096) - 512
    ci = Nx.quotient(Nx.right_shift(ids, 12) * 768, 4096) - 384
    zero = Nx.broadcast(Nx.tensor(0, type: :u32), Nx.shape(ids))

    {_, _, _, _, counts, _, _} =
      while {n = iterations, zr = zero, zi = zero, esc = zero, counts = zero, cr, ci}, n > 0 do
        r2 = asr8(zr * zr)
        i2 = asr8(zi * zi)
        escaped = Nx.bitwise_or(esc, Nx.as_type(r2 + i2 > 1024, :u32))
        nr = Nx.select(escaped == 0, r2 - i2 + cr, zr)
        ni = Nx.select(escaped == 0, asr8(2 * (zr * zi)) + ci, zi)
        {n - 1, nr, ni, escaped, counts + Nx.as_type(escaped == 0, :u32), cr, ci}
      end

    counts
  end

  defnp asr8(value) do
    Nx.bitwise_or(
      Nx.right_shift(value, 8),
      Nx.select(Nx.right_shift(value, 31) == 0, Nx.u32(0), Nx.u32(0xFF000000))
    )
  end

  defn checksum(ids, iterations) do
    times = pixels(ids, iterations)
    buckets = Nx.min(Nx.quotient(times * 8, iterations), 7)
    membership = Nx.new_axis(buckets, -1) == Nx.iota({8}, type: :u32)
    hist = Nx.as_type(Nx.sum(membership, axes: [0]), :u32)
    lut = Nx.quotient(Nx.cumulative_sum(hist) * 255, Nx.axis_size(ids, 0)) |> Nx.as_type(:u32)
    colours = Nx.take(lut, buckets)
    recolour = Nx.as_type(Nx.sum(colours * (ids * 2_654_435_761 + 1) + times), :u32)

    {_, mix, _} =
      while {i = 0, mix = Nx.u32(0), lut}, i < 8 do
        {i + 1, mix * 2_654_435_761 + lut[i], lut}
      end

    mix * 2_654_435_761 + recolour
  end
end
