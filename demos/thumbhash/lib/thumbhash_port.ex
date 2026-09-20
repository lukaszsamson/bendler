defmodule Bendler.Demos.ThumbhashPort do
  @moduledoc """
  ThumbHash encoding (`demos/thumbhash/thumbhash.bend`), run as a port.
  Start it with `start_link/1`.

  `thumbhash_bytes(w, h, rgba)` takes the pixels as a binary (the prelude's
  `Bytes`) and answers the hash bytes as a list; `thumbhash/3` is the same
  over a list of bytes. `encode/3` wraps the result in a binary.
  """
  use Bendler, otp_app: :bendler, source: "demos/thumbhash/thumbhash.bend", backend: :port

  @doc "The ThumbHash of a `w`x`h` RGBA binary, as a binary."
  @spec encode(1..100, 1..100, binary) :: binary
  def encode(w, h, rgba) when byte_size(rgba) == w * h * 4 do
    :binary.list_to_bin(thumbhash_bytes(w, h, rgba))
  end

  @doc "The ThumbHashes of many `w`x`h` RGBA binaries, encoded in parallel."
  @spec encode_batch(1..100, 1..100, [binary]) :: [binary]
  def encode_batch(w, h, images) do
    w
    |> batch_thumbhash_bytes(h, images)
    |> Enum.map(&:binary.list_to_bin/1)
  end
end
