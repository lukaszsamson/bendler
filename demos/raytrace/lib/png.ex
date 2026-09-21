defmodule Bendler.Demos.Raytrace.Png do
  @moduledoc """
  A minimal PNG writer, so the demo can save what it rendered: 8-bit
  truecolour, no interlace, one `:zlib` stream, every scanline filtered
  with filter type 0. Enough for `Bendler.Demos.RaytracePort.save_png/5`,
  not a general PNG library. `Bendler.Demos.Raytrace.Apng` reuses its
  signature, scanline filtering, zlib stream and chunk framing.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc "The PNG signature bytes."
  @spec signature() :: binary
  def signature, do: @signature

  @doc "The IHDR payload of a `w` x `h` 8-bit truecolour image."
  @spec ihdr(pos_integer, pos_integer) :: binary
  def ihdr(w, h), do: <<w::32, h::32, 8, 2, 0, 0, 0>>

  @doc "A `w` x `h` RGB binary (three bytes per pixel) as a PNG binary."
  @spec encode(pos_integer, pos_integer, binary) :: binary
  def encode(w, h, rgb) when byte_size(rgb) == w * h * 3 do
    @signature <>
      chunk("IHDR", ihdr(w, h)) <>
      chunk("IDAT", deflate(scanlines(w, h, rgb))) <>
      chunk("IEND", "")
  end

  @doc "Every row of `rgb` preceded by its filter byte (0: none)."
  @spec scanlines(pos_integer, pos_integer, binary) :: binary
  def scanlines(w, h, rgb) do
    for y <- 0..(h - 1), into: <<>>, do: <<0, :binary.part(rgb, y * w * 3, w * 3)::binary>>
  end

  @doc "One complete zlib stream over `data`."
  @spec deflate(iodata) :: binary
  def deflate(data) do
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

  @doc "A PNG chunk: its length, type, payload and CRC."
  @spec chunk(binary, binary) :: binary
  def chunk(type, data) do
    crc = :erlang.crc32(type <> data)
    <<byte_size(data)::32, type::binary, data::binary, crc::32>>
  end
end
