defmodule Bendler.Demos.SortingTest do
  use ExUnit.Case, async: false
  alias Bendler.Demos.SortingPort

  for threads <- [1, 4] do
    @threads threads
    test "sort and sets match Elixir with #{threads} workers" do
      start_supervised!({SortingPort, threads: @threads})
      :rand.seed(:exsss, {9, 82, 13})

      cases = [[], [0], [4_294_967_295], [0, 4_294_967_295, 4_294_967_295, 1, 0]]
      cases = cases ++ [List.duplicate(7, 33), Enum.to_list(0..64), Enum.to_list(64..0//-1)]

      random =
        for n <- [2, 3, 7, 8, 9, 31, 32, 33, 127, 128, 129, 1025] do
          for _ <- 1..n, do: :rand.uniform(4_294_967_296) - 1
        end

      for xs <- cases ++ random do
        assert SortingPort.identity(xs) == xs
        assert SortingPort.sort(xs) == Enum.sort(xs)
        assert SortingPort.unique(xs) == Enum.sort(Enum.uniq(xs))
      end

      pairs = for a <- cases, b <- cases, do: {a, b}
      pairs = pairs ++ Enum.zip(random, Enum.reverse(random))

      for {a, b} <- pairs do
        sa = MapSet.new(a)
        sb = MapSet.new(b)
        assert SortingPort.union(a, b) == Enum.sort(MapSet.union(sa, sb))
        assert SortingPort.intersection(a, b) == Enum.sort(MapSet.intersection(sa, sb))
        assert SortingPort.difference(a, b) == Enum.sort(MapSet.difference(sa, sb))
      end
    end
  end

  test "duplicate-heavy randomized sets and set identities" do
    start_supervised!({SortingPort, threads: 4})
    :rand.seed(:exsss, {74, 2, 91})

    for _ <- 1..30 do
      a = for _ <- 1..:rand.uniform(100), do: :rand.uniform(32) - 1
      b = for _ <- 1..:rand.uniform(100), do: :rand.uniform(32) - 1
      expected = a |> MapSet.new() |> MapSet.intersection(MapSet.new(b)) |> Enum.sort()
      assert SortingPort.intersection(a, b) == expected
      assert SortingPort.union(a, a) == SortingPort.unique(a)
      assert SortingPort.difference(a, a) == []

      assert SortingPort.difference(a, b) ==
               Enum.sort(MapSet.difference(MapSet.new(a), MapSet.new(b)))
    end
  end

  test "codec rejects values outside U32 before dispatch" do
    for xs <- [[-1], [4_294_967_296], [1.0], [:bad]] do
      assert_raise ArgumentError, fn -> SortingPort.sort(xs) end
    end
  end
end
