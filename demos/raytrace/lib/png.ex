defmodule Bendler.Demos.Raytrace.Png do
  @moduledoc """
  A minimal PNG writer, so the demo can save what it rendered: 8-bit
  truecolour, no interlace, one `:zlib` stream, every scanline filtered
  with filter type 0. Enough for `Bendler.Demos.RaytracePort.save_png/5`,
  not a general PNG library.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc "A `w` x `h` RGB binary (three bytes per pixel) as a PNG binary."
  @spec encode(pos_integer, pos_integer, binary) :: binary
  def encode(w, h, rgb) when byte_size(rgb) == w * h * 3 do
    header = <<w::32, h::32, 8, 2, 0, 0, 0>>

    @signature <>
      chunk("IHDR", header) <>
      chunk("IDAT", deflate(scanlines(w, h, rgb))) <>
      chunk("IEND", "")
  end

  # every row preceded by its filter byte (0: none)
  defp scanlines(w, h, rgb) do
    for y <- 0..(h - 1), into: <<>>, do: <<0, :binary.part(rgb, y * w * 3, w * 3)::binary>>
  end

  defp deflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, :default)
      out = :zlib.deflate(z, data, :finish)
      :ok = :zlib.deflateEnd(z)
      IO.iodata_to_binary(out)
    after
      :ok = :zlib.close(z)
    end
  end

  defp chunk(type, data) do
    crc = :erlang.crc32(type <> data)
    <<byte_size(data)::32, type::binary, data::binary, crc::32>>
  end
end
