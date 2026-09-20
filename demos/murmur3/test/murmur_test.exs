defmodule Bendler.MurmurTest do
  use ExUnit.Case, async: false

  alias Bendler.Examples.MurmurPort
  alias Bendler.Test.MurmurReference

  # Known answers from MurmurTest ("x86_32"), verbatim: {data, seed, hash}.
  # Includes the moduledoc doctest row.
  @known_answers [
    {"", 0, 0},
    {"", 1, 1_364_076_727},
    {"0", 0, 3_530_670_207},
    {"01", 0, 1_642_882_560},
    {"012", 0, 3_966_566_284},
    {"0123", 0, 3_558_446_240},
    {"01234", 0, 433_070_448},
    {"b2622f5e1310a0aa14b7f957fe4246fa", 2_147_368_987, 3_297_211_900}
  ]

  # Block/tail boundary vectors from MurmurTest (@boundary_vectors,
  # :hash_x86_32), verbatim hex: size => hash of bytes 0..size-1.
  # Lengths mod 4 hit 0, 1, 2, 3 remainders across 0, 1, 2, 8 blocks.
  @boundary_vectors [
    {0, 0x00000000},
    {1, 0x514E28B7},
    {3, 0x51D4D0D7},
    {4, 0xF4C0EC39},
    {5, 0xCCA4DCCB},
    {7, 0x8D7E4914},
    {8, 0xD161D673},
    {9, 0xE7E27A50},
    {15, 0x5BD6952D},
    {16, 0x191573DD},
    {17, 0xCBE58DC6},
    {31, 0x64426AD6},
    {32, 0xCAC37638},
    {33, 0x5460867A}
  ]

  setup do
    %{pid: start_supervised!({MurmurPort, []})}
  end

  defp hash_bin(bin, seed), do: MurmurPort.murmur3_x86_32(:binary.bin_to_list(bin), seed)

  defp sequential_bytes(0), do: <<>>

  defp sequential_bytes(size) do
    for byte <- 0..(size - 1), into: <<>>, do: <<byte>>
  end

  describe "OSS vectors" do
    test "known answers" do
      for {data, seed, expected} <- @known_answers do
        assert hash_bin(data, seed) == expected,
               "murmur3(#{inspect(data)}, #{seed})"

        assert MurmurReference.hash_x86_32(data, seed) == expected
      end
    end

    test "block and tail boundaries" do
      for {size, expected} <- @boundary_vectors do
        bin = sequential_bytes(size)

        assert hash_bin(bin, 0) == expected,
               "murmur3(sequential #{size} bytes)"

        assert MurmurReference.hash_x86_32(bin, 0) == expected
      end
    end
  end

  describe "differential tests against the reference" do
    test "lengths 0..40 under seeds 0, 1 and max hit every tail class" do
      for len <- 0..40,
          seed <- [0, 1, 0xFFFFFFFF] do
        bin = for i <- 0..(len - 1)//1, into: <<>>, do: <<rem(i * 37 + 11, 256)>>

        assert hash_bin(bin, seed) == MurmurReference.hash_x86_32(bin, seed),
               "len #{len} seed #{seed}"
      end
    end

    test "every single byte value" do
      for byte <- 0..255 do
        bin = <<byte>>

        assert hash_bin(bin, 0) == MurmurReference.hash_x86_32(bin, 0),
               "byte #{byte}"
      end
    end

    test "multibyte UTF-8 hashes as raw bytes" do
      for s <- ["zażółć", "café", "naïve", "hello zażółć", "é"] do
        assert hash_bin(s, 0) == MurmurReference.hash_x86_32(s, 0)

        assert hash_bin(s, 0x9747B28C) == MurmurReference.hash_x86_32(s, 0x9747B28C)
      end
    end

    test "Erlang-term-style binaries agree byte for byte" do
      term = %{tuple: {:ok, 42}, nested: [nil, true, <<0, 255>>]}
      bin = :erlang.term_to_binary(term)

      for seed <- [0, 0xFFFFFFFF] do
        assert hash_bin(bin, seed) == MurmurReference.hash_x86_32(bin, seed)
      end
    end
  end

  describe "batched hashing" do
    test "a batch over the seed-0 known answers matches the singles" do
      rows = Enum.filter(@known_answers, fn {_, seed, _} -> seed == 0 end)
      datas = Enum.map(rows, fn {data, _, _} -> :binary.bin_to_list(data) end)
      expected = Enum.map(rows, fn {_, _, h} -> h end)

      assert MurmurPort.batch_murmur3(datas, 0) == expected
    end

    test "batch edges: empty and one input" do
      assert MurmurPort.batch_murmur3([], 0) == []
      assert MurmurPort.batch_murmur3([:binary.bin_to_list("abc")], 0) == [hash_bin("abc", 0)]
    end

    test "a 64-input batch matches the reference" do
      bins = for i <- 0..63, do: "input-#{i}-#{String.duplicate("x", rem(i, 9))}"
      datas = Enum.map(bins, &:binary.bin_to_list/1)
      expected = Enum.map(bins, &MurmurReference.hash_x86_32(&1, 12_345))

      assert MurmurPort.batch_murmur3(datas, 12_345) == expected
    end
  end

  describe "Bytes" do
    test "the Bytes export agrees with the list export on every boundary length" do
      for n <- 0..40, seed <- [0, 1, 0xFFFFFFFF] do
        bin = :crypto.strong_rand_bytes(n)
        assert MurmurPort.hash(bin, seed) == MurmurPort.murmur3_x86_32(:binary.bin_to_list(bin), seed)
      end
    end

    test "a batch of binaries agrees with single calls" do
      bins = for n <- 1..64, do: :crypto.strong_rand_bytes(n)
      assert MurmurPort.hash_batch(bins, 7) == Enum.map(bins, &MurmurPort.hash(&1, 7))
    end
  end
end
