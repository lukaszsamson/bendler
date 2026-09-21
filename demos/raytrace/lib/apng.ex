defmodule Bendler.Demos.Raytrace.Apng do
  @moduledoc """
  An animated PNG writer that appends frames as they arrive.

  APNG is ordinary PNG plus three chunks: `acTL` (how many frames and how
  often to loop) before the image data, an `fcTL` before each frame, and
  `fdAT` (a sequence number and a zlib stream) for every frame after the
  first, whose data is the plain `IDAT`. Every frame is a full-size,
  lossless truecolour image filtered and deflated by
  `Bendler.Demos.Raytrace.Png`, so no palette or quantisation is involved
  and any browser opens the result.

  `open/4` writes the header, `frame/2` appends one, and `close/1` writes
  `IEND` and corrects `acTL` if fewer frames arrived than were announced.
  Nothing is buffered: the file on disk grows while the render runs.
  """
  alias Bendler.Demos.Raytrace.Png

  @enforce_keys [:io, :w, :h, :announced, :delay]
  defstruct [:io, :w, :h, :announced, :delay, frames: 0, seq: 0]

  @typedoc "A writer in progress."
  @opaque t :: %__MODULE__{}

  # signature + the IHDR chunk; acTL's payload starts eight bytes into it
  @actl_offset 8 + 12 + 13 + 8

  @doc """
  Starts an APNG at `path` for `frames` frames of `w` x `h`. Options:
  `:delay` is the `{numerator, denominator}` of a frame's duration in
  seconds (default `{1, 20}`), `:plays` how often to loop (0, the
  default, is forever).
  """
  @spec open(Path.t(), pos_integer, pos_integer, keyword) :: t
  def open(path, w, h, opts \\ []) do
    file = File.open!(path, [:write, :binary, :raw])
    plays = Keyword.get(opts, :plays, 0)
    announced = Keyword.fetch!(opts, :frames)

    :ok =
      :file.write(
        file,
        Png.signature() <>
          Png.chunk("IHDR", Png.ihdr(w, h)) <>
          Png.chunk("acTL", <<announced::32, plays::32>>)
      )

    %__MODULE__{
      io: file,
      w: w,
      h: h,
      announced: announced,
      delay: Keyword.get(opts, :delay, {1, 20})
    }
  end

  @doc "Appends one frame: a `w * h * 3` RGB binary, row-major."
  @spec frame(t, binary) :: t
  def frame(%__MODULE__{w: w, h: h} = a, rgb) when byte_size(rgb) == w * h * 3 do
    data = Png.deflate(Png.scanlines(w, h, rgb))
    {num, den} = a.delay
    control = Png.chunk("fcTL", <<a.seq::32, w::32, h::32, 0::32, 0::32, num::16, den::16, 0, 0>>)

    payload =
      if a.frames == 0,
        do: Png.chunk("IDAT", data),
        else: Png.chunk("fdAT", <<a.seq + 1::32, data::binary>>)

    :ok = :file.write(a.io, control <> payload)
    %{a | frames: a.frames + 1, seq: a.seq + if(a.frames == 0, do: 1, else: 2)}
  end

  @doc """
  Writes `IEND`, corrects `acTL` when fewer frames arrived than were
  announced (a cancelled fly-through), and closes the file. Answers how
  many frames the file holds.
  """
  @spec close(t) :: non_neg_integer
  def close(%__MODULE__{} = a) do
    :ok = :file.write(a.io, Png.chunk("IEND", ""))
    if a.frames != a.announced, do: fix_count(a)
    :ok = :file.close(a.io)
    a.frames
  end

  # acTL is at a fixed offset: its payload and CRC are rewritten in place
  defp fix_count(a) do
    payload = <<a.frames::32, 0::32>>
    :ok = :file.pwrite(a.io, @actl_offset, payload <> <<:erlang.crc32("acTL" <> payload)::32>>)
  end

  @doc """
  The `{type, payload}` chunks of a PNG or APNG binary, in order, with
  every CRC verified. Raises `ArgumentError` on a malformed file.
  """
  @spec chunks(binary) :: [{binary, binary}]
  def chunks(<<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>>), do: chunks(rest, [])
  def chunks(_), do: raise(ArgumentError, "not a PNG file")

  defp chunks(<<>>, acc), do: Enum.reverse(acc)

  defp chunks(<<n::32, type::binary-size(4), data::binary-size(n), crc::32, rest::binary>>, acc) do
    if :erlang.crc32(type <> data) != crc, do: raise(ArgumentError, "bad CRC in #{type}")
    chunks(rest, [{type, data} | acc])
  end

  defp chunks(_, _), do: raise(ArgumentError, "a truncated chunk")
end
