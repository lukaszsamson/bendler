defmodule Bendler.Demos.ThumbhashTest do
  use ExUnit.Case, async: false

  alias Bendler.Demos.{ThumbhashPort, ThumbhashReference}

  setup_all do
    start_supervised!({ThumbhashPort, []})
    :ok
  end

  # deterministic pseudo-random RGBA pixels (opaque unless alpha: true)
  defp image(w, h, seed, opts \\ []) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 5})
    alpha = Keyword.get(opts, :alpha, false)

    for _ <- 1..(w * h), into: <<>> do
      a = if alpha, do: :rand.uniform(256) - 1, else: 255
      <<:rand.uniform(256) - 1, :rand.uniform(256) - 1, :rand.uniform(256) - 1, a>>
    end
  end

  defp gradient(w, h) do
    for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
      <<div(x * 255, max(w - 1, 1)), div(y * 255, max(h - 1, 1)), 128, 255>>
    end
  end

  # Bend computes in F32, the reference in doubles: a coefficient that sits
  # on a quantisation boundary may round to the neighbouring level. Two
  # hashes agree when every byte is equal, or every field differs by at
  # most one quantisation step; the test reports how many were exact.
  defp within_one_step?(a, b) when byte_size(a) == byte_size(b) do
    Enum.zip(:binary.bin_to_list(a), :binary.bin_to_list(b))
    |> Enum.all?(fn {x, y} -> nibbles_close?(x, y) end)
  end

  defp within_one_step?(_, _), do: false

  defp nibbles_close?(x, y) do
    import Bitwise
    abs((x &&& 15) - (y &&& 15)) <= 1 and abs((x >>> 4) - (y >>> 4)) <= 1
  end

  test "the flower image hashes as the reference does, and as documented up to its flag bug" do
    rgba = File.read!(Path.join(__DIR__, "flower_75x100.rgba"))
    hash = ThumbhashPort.encode(75, 100, rgba)
    ref = ThumbhashReference.encode(75, 100, rgba)
    # 75x100 opaque: lx 5, ly 7 -> 22 + 5 + 5 ac nibbles -> 5 + 16 bytes
    assert byte_size(hash) == 21
    assert within_one_step?(hash, ref)
    # The documented vector was produced by thumbhash-ex's own code from
    # pixels decoded by a different JPEG decoder; the image is portrait, so
    # the reference's flag bug (see ThumbhashReference) does not bite here
    # and the two agree to within one quantisation step.
    documented = Base.decode64!("k0oGLQaSVsN0BVhn2oq2Z5SQUQcZ")
    assert within_one_step?(hash, documented)
    # portrait: the landscape flag (bit 15 of header16) is clear
    assert Bitwise.band(:binary.at(hash, 4), 0x80) == 0
  end

  test "opaque images match the reference, most of them exactly" do
    cases = [{1, 1, 1}, {2, 3, 2}, {8, 8, 3}, {16, 9, 4}, {9, 16, 5}, {32, 32, 6}, {100, 100, 7}, {100, 1, 8}]

    results =
      for {w, h, seed} <- cases do
        rgba = image(w, h, seed)
        ref = ThumbhashReference.encode(w, h, rgba)
        got = ThumbhashPort.encode(w, h, rgba)
        assert within_one_step?(got, ref), "#{w}x#{h} seed #{seed}: #{inspect(got)} vs #{inspect(ref)}"
        got == ref
      end

    # F32 vs doubles: most are exact, the rest one quantisation step off
    assert Enum.count(results, & &1) >= div(length(results), 2)
  end

  test "images with transparency take the alpha path" do
    for {w, h, seed} <- [{4, 4, 11}, {20, 10, 12}, {50, 60, 13}] do
      rgba = image(w, h, seed, alpha: true)
      ref = ThumbhashReference.encode(w, h, rgba)
      got = ThumbhashPort.encode(w, h, rgba)
      # the alpha flag is bit 23 of header24, i.e. bit 7 of the third byte
      assert Bitwise.band(:binary.at(got, 2), 0x80) == 0x80
      assert within_one_step?(got, ref)
    end
  end

  test "flat colours agree on the header; a symmetric gradient sits on rounding ties" do
    # a flat image's ac coefficients are float noise around 0, normalised
    # by a near-zero scale: their nibbles are arbitrary in any
    # implementation (the reference's included), but the header (dc, a
    # scale that rounds to 0, the flags) is determined
    for {w, h, rgba} <- [
          {10, 10, :binary.copy(<<200, 30, 30, 255>>, 100)},
          {5, 7, :binary.copy(<<0, 0, 0, 255>>, 35)},
          {3, 3, :binary.copy(<<255, 255, 255, 255>>, 9)}
        ] do
      got = ThumbhashPort.encode(w, h, rgba)
      ref = ThumbhashReference.encode(w, h, rgba)
      assert byte_size(got) == byte_size(ref)
      assert binary_part(got, 0, 5) == binary_part(ref, 0, 5)
    end

    # a linear gradient makes every even harmonic ~0, i.e. 0.5 * 15 = 7.5:
    # exactly the rounding tie, where F32 and doubles part ways
    rgba = gradient(30, 20)
    got = ThumbhashPort.encode(30, 20, rgba)
    ref = ThumbhashReference.encode(30, 20, rgba)
    assert binary_part(got, 0, 5) == binary_part(ref, 0, 5)
    assert within_one_step?(got, ref)
  end

  test "an image that does not fit answers no bytes" do
    assert ThumbhashPort.thumbhash(101, 1, List.duplicate(0, 404)) == []
  end

  test "the Bytes and list exports agree" do
    rgba = image(12, 9, 21)
    assert ThumbhashPort.thumbhash_bytes(12, 9, rgba) == ThumbhashPort.thumbhash(12, 9, :binary.bin_to_list(rgba))
  end

  test "a batch encodes every image and agrees with single calls" do
    images = for seed <- 1..16, do: image(24, 16, seed)
    assert ThumbhashPort.encode_batch(24, 16, images) == Enum.map(images, &ThumbhashPort.encode(24, 16, &1))
    assert ThumbhashPort.encode_batch(24, 16, []) == []
  end
end
