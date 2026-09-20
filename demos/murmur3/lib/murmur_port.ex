defmodule Bendler.Examples.MurmurPort do
  @moduledoc "Murmur3 x86_32 (`demos/murmur3/murmur.bend`), run as a port. Bytes cross as `List<U32>`. Start it with `start_link/1`."
  @doc "The hash of a binary, crossing as Bytes (no list cell per byte)."
  @spec hash(binary, non_neg_integer) :: non_neg_integer
  def hash(bin, seed \\ 0) when is_binary(bin), do: murmur3(bin, seed)

  @doc "The hashes of many binaries under one seed, in parallel."
  @spec hash_batch([binary], non_neg_integer) :: [non_neg_integer]
  def hash_batch(bins, seed \\ 0), do: batch_murmur3_bytes(bins, seed)

  use Bendler, otp_app: :bendler, source: "demos/murmur3/murmur.bend", backend: :port
end
