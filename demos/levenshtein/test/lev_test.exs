defmodule Bendler.LevTest do
  use ExUnit.Case, async: false

  alias Bendler.Examples.LevPort
  alias Bendler.Test.LevReference

  # Every case of Simetric.LevenshteinTest, verbatim: {a, b} => distance.
  # Simetric compares graphemes; all of these are ASCII, where graphemes
  # and code points coincide, so Bend must agree on every one.
  @simetric_cases [
    {"", "", 0},
    {"", "ab", 2},
    {"abc", "", 3},
    {"a", "a", 0},
    {"abc", "abc", 0},
    {"a", "ab", 1},
    {"b", "ab", 1},
    {"ac", "abc", 1},
    {"abcdefg", "xabxcdxxefxgx", 6},
    {"a", "", 1},
    {"ab", "a", 1},
    {"ab", "b", 1},
    {"abc", "ac", 1},
    {"xabxcdxxefxgx", "abcdefg", 6},
    {"a", "b", 1},
    {"ab", "ac", 1},
    {"ac", "bc", 1},
    {"abc", "axc", 1},
    {"xabxcdxxefxgx", "1ab2cd34ef5g6", 6},
    {"example", "samples", 3},
    {"sturgeon", "urgently", 6},
    {"levenshtein", "frankenstein", 6},
    {"distance", "difference", 5}
  ]

  # Every case of TheFuzz's lev­enshtein_test, with the empty-argument
  # rows adapted: the_fuzz answers `nil` there, Bend answers the other
  # length (Simetric semantics). the_fuzz compares code points
  # (`String.to_charlist/1`), same as Bend.
  @the_fuzz_cases [
    {"a", "a", 0},
    {"abc", "abc", 0},
    {"123", "123", 0},
    {"abc", "xyz", 3},
    {"123", "456", 3},
    {"abc", "a", 2},
    {"a", "abc", 2},
    {"abc", "c", 2},
    {"c", "abc", 2},
    {"sitting", "kitten", 3},
    {"kitten", "sitting", 3},
    {"cake", "drake", 2},
    {"drake", "cake", 2},
    {"saturday", "sunday", 3},
    {"sunday", "saturday", 3},
    {"book", "back", 2},
    {"dog", "fog", 1},
    {"foq", "fog", 1},
    {"fvg", "fog", 1},
    {"encyclopedia", "encyclopediaz", 1},
    {"encyclopediz", "encyclopediaz", 1},
    {"abc", "", 3},
    {"", "xyz", 3},
    {"", "", 0}
  ]

  # Precomposed Unicode: graphemes and code points coincide, so the
  # grapheme reference agrees too. Values checked against a Python
  # code-point implementation while writing the Bend program.
  @unicode_cases [
    {"zażółć", "zażółć", 0},
    {"zażółć", "zazolc", 4},
    {"café", "cafe", 1},
    {"naïve", "naive", 1},
    {"hello zażółć", "hello zazolc", 4}
  ]

  setup do
    %{pid: start_supervised!({LevPort, []})}
  end

  describe "single distances reused from the OSS suites" do
    test "every Simetric case" do
      for {a, b, expected} <- @simetric_cases do
        assert LevPort.levenshtein(a, b) == expected,
               "levenshtein(#{inspect(a)}, #{inspect(b)})"

        assert LevReference.codepoint(a, b) == expected
        assert LevReference.grapheme(a, b) == expected
      end
    end

    test "every the_fuzz case (empty rows take Simetric semantics)" do
      for {a, b, expected} <- @the_fuzz_cases do
        assert LevPort.levenshtein(a, b) == expected,
               "levenshtein(#{inspect(a)}, #{inspect(b)})"

        assert LevReference.codepoint(a, b) == expected
      end
    end

    test "precomposed Unicode matches both references" do
      for {a, b, expected} <- @unicode_cases do
        assert LevPort.levenshtein(a, b) == expected,
               "levenshtein(#{inspect(a)}, #{inspect(b)})"

        assert LevReference.codepoint(a, b) == expected
        assert LevReference.grapheme(a, b) == expected
      end
    end
  end

  describe "Unicode semantics: code points, not graphemes" do
    test "combining sequence vs precomposed char diverges from Simetric on purpose" do
      # "e" + combining acute (2 code points, 1 grapheme) vs "é" (1 and 1)
      a = "é"
      b = "é"
      assert String.to_charlist(a) == [101, 769]
      assert String.to_charlist(b) == [233]

      assert LevReference.codepoint(a, b) == 2
      assert LevReference.grapheme(a, b) == 1
      assert LevPort.levenshtein(a, b) == 2
    end

    test "invalid bytes become U+FFFD before the comparison" do
      assert LevPort.levenshtein(<<0xFF>>, "") == 1
      assert LevPort.levenshtein(<<0xFF>>, "�") == 0
      assert LevPort.levenshtein(<<0xFF, 0xFE>>, "ab") == LevReference.codepoint("��", "ab")
    end
  end

  describe "batched distances" do
    test "a batch over the Simetric pairs matches the singles" do
      {as, bs, expected} =
        Enum.reduce(@simetric_cases, {[], [], []}, fn {a, b, d}, {as, bs, ds} ->
          {[a | as], [b | bs], [d | ds]}
        end)

      as = Enum.reverse(as)
      bs = Enum.reverse(bs)
      expected = Enum.reverse(expected)

      assert LevPort.batch_levenshtein(as, bs) == expected

      assert Enum.zip(as, bs) |> Enum.map(fn {a, b} -> LevPort.levenshtein(a, b) end) ==
               expected
    end

    test "batch edges: empty, truncation, one pair" do
      assert LevPort.batch_levenshtein([], []) == []
      assert LevPort.batch_levenshtein(["a", "b"], ["a"]) == [0]
      assert LevPort.batch_levenshtein(["a"], ["a", "b"]) == [0]
      assert LevPort.batch_levenshtein(["kitten"], ["sitting"]) == [3]
    end

    test "a 64-pair batch matches the code-point reference" do
      pairs = for i <- 0..63, do: {"word#{i} kitten", "word#{i} sitting"}
      {as, bs} = Enum.unzip(pairs)
      expected = Enum.map(pairs, fn {a, b} -> LevReference.codepoint(a, b) end)

      assert LevPort.batch_levenshtein(as, bs) == expected
      assert Enum.all?(expected, &(&1 == 3))
    end

    test "distance laws on a fixed set" do
      strings = ["", "a", "kitten", "sitting", "saturday", "sunday", "zażółć", "zazolc"]

      for a <- strings, b <- strings do
        d = LevPort.levenshtein(a, b)
        # symmetric, and at least the length gap
        assert d == LevPort.levenshtein(b, a)
        assert d >= abs(String.length(a) - String.length(b))
        assert d == LevReference.codepoint(a, b)
      end
    end
  end
end
