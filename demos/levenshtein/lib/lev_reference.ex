defmodule Bendler.Test.LevReference do
  @moduledoc """
  Pure-Elixir references for the `demos/levenshtein/lev.bend` differential tests.

  `codepoint/2` is the semantics Bend implements: two-row Levenshtein
  over Unicode code points (`String.to_charlist/1`), with an empty
  string answering the other length.

  `grapheme/2` is `Simetric.Levenshtein.compare/2` verbatim (graphemes
  via `String.graphemes/1`, lengths via `String.length/1`). The two
  agree wherever graphemes and code points coincide and diverge on
  combining sequences, which is what the Unicode test pins down.
  """

  @doc "Levenshtein over code points; `{\"\", s}` answers the length of `s`."
  @spec codepoint(String.t(), String.t()) :: non_neg_integer()
  def codepoint(a, b), do: distance(String.to_charlist(a), String.to_charlist(b))

  defp distance(c1, []), do: length(c1)
  defp distance([], c2), do: length(c2)

  defp distance(c1, c2) do
    prev = Enum.to_list(0..length(c2))
    {row, _} = Enum.reduce(c1, {prev, 1}, &step(&1, &2, c2))
    List.last(row)
  end

  defp step(c1, {prev, i}, c2) do
    {row, _, _} =
      Enum.reduce(Enum.zip(c2, Enum.drop(prev, 1)), {[i], i, hd(prev)}, fn
        {x2, p}, {[cur_prev | _] = acc, _, diag} ->
          cost = if c1 == x2, do: 0, else: 1
          cur = min(min(p + 1, cur_prev + 1), diag + cost)
          {[cur | acc], cur, p}
      end)

    {Enum.reverse(row), i + 1}
  end

  @doc "Simetric's grapheme Levenshtein, copied for the divergence test."
  @spec grapheme(String.t(), String.t()) :: non_neg_integer()
  def grapheme(string, string), do: 0
  def grapheme(string1, ""), do: String.length(string1)
  def grapheme("", string2), do: String.length(string2)

  def grapheme(string1, string2) do
    chars1 = String.graphemes(string1)
    chars2 = String.graphemes(string2)
    distance_g(chars1, chars2, Enum.to_list(length(chars2)..0//-1), 1)
  end

  defp distance_g([], _, [result | _], _), do: result

  defp distance_g([char | rest], chars2, distlist, step) do
    distlist = proceed(char, chars2, Enum.reverse(distlist), [step], step)
    distance_g(rest, chars2, distlist, step + 1)
  end

  defp proceed(_, [], _, acc, _), do: acc

  defp proceed(char1, [char2 | rest], [head | [prev | _] = distlist], acc, score) do
    diff = if char1 == char2, do: 0, else: 1
    score = min(min(score + 1, prev + 1), head + diff)
    proceed(char1, rest, distlist, [score | acc], score)
  end
end
