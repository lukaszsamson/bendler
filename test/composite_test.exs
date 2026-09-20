defmodule Bendler.CompositeTest do
  use ExUnit.Case, async: false
  alias Bendler.{Codec, Sig}
  alias Bendler.Test.{CompositeNif, CompositePort}

  test "signature grammar preserves nested tuples and error-first Result" do
    assert Sig.parse_type("U32 & String & Bool") == {:ok, {:tuple, [:u32, :string, :bool]}}

    assert Sig.parse_type("(U32 & String) & Bool") ==
             {:ok, {:tuple, [{:tuple, [:u32, :string]}, :bool]}}

    assert Sig.parse_type("Result<&2, &2, U32 & String, Maybe<List<U32>>>") ==
             {:ok, {:result, {:tuple, [:u32, :string]}, {:maybe, {:list, :u32}}}}

    for bad <- [
          "Maybe<>",
          "Result<U32>",
          "Result<&2, U32, String>",
          Enum.join(List.duplicate("U32", 17), " & "),
          "(U32",
          "U32 &",
          "List<U32>>",
          "Maybe<" <> String.duplicate("List<", 40) <> "U32" <> String.duplicate(">", 41)
        ] do
      assert {:error, _} = Sig.parse_type(bad)
    end
  end

  for backend <- [CompositePort, CompositeNif] do
    @backend backend
    test "composites round trip through #{inspect(backend)}" do
      if @backend == CompositePort, do: start_supervised!({CompositePort, []})
      assert @backend.pair({4_294_967_295, "zażółć"}) == {4_294_967_295, "zażółć"}
      assert @backend.triple({17, "", false}) == {17, "", false}
      assert @backend.right({17, {"", false}}) == {17, {"", false}}
      wide = List.to_tuple(Enum.to_list(0..15))
      assert @backend.wide(wide) == wide
      nested = {{1, "a"}, [:none, {:some, 7}]}
      assert @backend.nested(nested) == nested
      for v <- [:none, {:some, :none}, {:some, {:some, 0}}], do: assert(@backend.optional(v) == v)

      for v <- [{:ok, []}, {:ok, [:none, {:some, 8}]}, {:error, {9, "bad input"}}],
          do: assert(@backend.result(v) == v)

      blob = {:some, {:ok, {<<0, 255, 128>>, {:some, <<>>}}}}
      assert @backend.blob(blob) == blob
      assert @backend.blob({:some, {:error, 12}}) == {:some, {:error, 12}}
      assert @backend.empty([]) == []

      assert @backend.empty([:none, {:some, {:ok, []}}, {:some, {:error, {1, "e"}}}]) ==
               [:none, {:some, {:ok, []}}, {:some, {:error, {1, "e"}}}]
    end
  end

  test "Result failure is data, not a transport failure" do
    assert Codec.reply(
             Codec.encode({:error, {1, "bad"}}, {:result, {:tuple, [:u32, :string]}, :unit})
           ) == {:error, {1, "bad"}}

    assert_raise Bendler.Error, fn -> Codec.reply(<<0, 3::32, "bad">>) end
    assert_raise Bendler.Error, fn -> Codec.decode(:binary.copy(<<10>>, 40) <> <<9>>) end

    for frame <- [<<8, 0>>, <<8, 17>>, <<8, 2, 5>>, <<10>>, <<11>>, <<12>>, <<11, 0, 0::32>>],
        do: assert_raise(Bendler.Error, fn -> Codec.decode(frame) end)

    for {bad, t} <- [{nil, {:maybe, :u32}}, {{1}, {:tuple, [:u32, :u32]}}],
        do: assert_raise(ArgumentError, fn -> Codec.encode(bad, t) end)
  end

  test "native validation rejects malformed composite frames without poisoning either runtime" do
    start_supervised!({CompositePort, []})
    assert CompositeNif.optional(:none) == :none

    frames = [
      # wrong pair arity
      <<0::32, 8, 3, 1, 1::32, 3, 0::32>>,
      # missing second field
      <<0::32, 8, 2, 1, 1::32>>,
      # Some without its payload
      <<3::32, 10>>,
      # trailing payload after None
      <<3::32, 9, 5>>,
      # Result success must contain a List
      <<4::32, 11, 1, 4::32>>,
      # truncated Result error tuple
      <<4::32, 12, 8, 2, 1, 4::32>>,
      # trailing value after an empty composite list
      <<6::32, 6, 0::32, 9>>
    ]

    for frame <- frames do
      assert_raise Bendler.Error, fn ->
        CompositePort |> Bendler.Port.call(frame) |> Codec.reply()
      end

      assert {:error, {:invalid, _}} = CompositeNif.__bendler_call(frame, 1000)
    end

    assert CompositePort.optional({:some, :none}) == {:some, :none}
    assert CompositeNif.result({:ok, []}) == {:ok, []}
  end

  test "F32, Char and Map signatures" do
    assert Sig.parse_type("F32") == {:ok, :f32}
    assert Sig.parse_type("List<&2, Char>") == {:ok, {:list, :char}}
    assert Sig.parse_type("Map<U32>") == {:ok, {:map, :u32}}
    assert Sig.parse_type("+Map<&2, List<B.Bytes>>") == {:ok, {:map, {:list, :bytes}}}
    assert Sig.parse_type("Map<(String & F32)>") == {:ok, {:map, {:tuple, [:string, :f32]}}}
    assert Sig.map_parts("Map<&2, List<B.Bytes>>") == {2, "List<B.Bytes>"}
    assert Sig.map_parts("+Map<U32>") == {1, "U32"}
    # a Map is a whole parameter or result, never a part of one
    for bad <- ["List<Map<U32>>", "Map<U32> & U32", "Maybe<Map<U32>>", "Map<>", "Map<&0, U32>"],
        do: assert({:error, _} = Sig.parse_type(bad))

    assert Sig.spec({:map, {:list, :f32}}) == "LT2:sLf"
    assert Sig.spec(:char) == "c"
  end

  for backend <- [CompositePort, CompositeNif] do
    @backend backend
    test "F32, Char and Map round trip through #{inspect(backend)}" do
      if @backend == CompositePort, do: start_supervised!({CompositePort, []})
      assert @backend.half(3.0) == 1.5
      # an Elixir double rounds to the nearest single on the way in
      assert @backend.half(0.1) == 0.05000000074505806
      assert @backend.half(-1.0e-45) == -0.0
      assert @backend.f32_div(1.0, 0.0) == :infinity
      assert @backend.f32_div(-1.0, 0.0) == :neg_infinity
      assert @backend.f32_div(0.0, 0.0) == :nan
      assert @backend.half(:nan) == :nan
      assert @backend.half(:infinity) == :infinity
      assert @backend.half(:neg_infinity) == :neg_infinity

      assert @backend.upper(?a) == ?A
      assert @backend.upper(0x1F600) == 0x1F600
      assert @backend.chars("zażółć") == String.to_charlist("zażółć")
      assert @backend.from_chars([?h, ?i, 0x10FFFF]) == "hi" <> <<0x10FFFF::utf8>>

      assert @backend.tally(~w(a b a c a b)) == %{"a" => 3, "b" => 2, "c" => 1}
      assert @backend.tally([]) == %{}
      assert @backend.total(%{"x" => 1, "y" => 2, "zz" => 39}) == 42
      assert @backend.total(%{}) == 0
      assert @backend.scale(%{"p" => 1.5, "q" => -2.0}, 2.0) == %{"p" => 3.0, "q" => -4.0}
      blobs = %{"" => [], "k" => [<<>>, <<1, 2, 3>>], "zażółć" => [<<255>>]}
      assert @backend.blobs(blobs) == blobs

      # 4096 keys exercise the trie past a few levels
      big = Map.new(1..4096, &{"key#{&1}", &1})
      assert @backend.total(big) == Enum.sum(1..4096)
    end
  end

  test "F32, Char and Map codec policies" do
    assert Codec.encode(1.0, :f32) == <<13, 1.0::float-32>>
    assert Codec.encode(:nan, :f32) == <<13, 0x7FC00000::32>>
    assert Codec.reply(<<13, 0xFF800000::32>>) == :neg_infinity
    assert Codec.reply(<<13, 0x7F800001::32>>) == :nan
    f32_max = 3.402_823_466_385_288_6e38
    assert Codec.reply(<<13, f32_max::float-32>>) == f32_max
    # past the single range: no silent infinity
    for bad <- [3.5e38, -3.5e38, 1, "1.0"],
        do: assert_raise(ArgumentError, fn -> Codec.encode(bad, :f32) end)

    assert Codec.encode(?é, :char) == <<14, ?é::32>>

    for bad <- [-1, 0xD800, 0xDFFF, 0x110000, "a"],
        do: assert_raise(ArgumentError, fn -> Codec.encode(bad, :char) end)

    # a reply Char is checked on the host: Bend can build any Chr{U32}
    assert_raise Bendler.Error, fn -> Codec.check(Codec.reply(<<14, 0xD800::32>>), :char, :f) end

    assert Codec.encode(%{"a" => 1}, {:map, :u32}) == <<6, 1::32, 8, 2, 3, 1::32, "a", 1, 1::32>>

    for bad <- [%{a: 1}, [{"a", 1}], %{"a" => -1}],
        do: assert_raise(ArgumentError, fn -> Codec.encode(bad, {:map, :u32}) end)

    assert Codec.check([{"a", 1}, {"b", 2}], {:map, :u32}, :f) == %{"a" => 1, "b" => 2}
  end

  test "native validation rejects a bad Char and an F32 of the wrong width" do
    start_supervised!({CompositePort, []})

    upper =
      Enum.find_index(
        elem(Sig.parse(File.read!("bend/composite.bend")), 0),
        &(&1.name == "upper")
      )

    half =
      Enum.find_index(elem(Sig.parse(File.read!("bend/composite.bend")), 0), &(&1.name == "half"))

    frames = [
      <<upper::32, 14, 0xD800::32>>,
      <<upper::32, 14, 0x110000::32>>,
      <<upper::32, 1, ?a::32>>,
      <<half::32, 13, 0, 0>>,
      <<half::32, 1, 0::32>>
    ]

    for frame <- frames do
      assert_raise Bendler.Error, ~r/expected an? (Char|F32)/, fn ->
        CompositePort |> Bendler.Port.call(frame) |> Codec.reply()
      end

      assert {:error, {:invalid, _}} = CompositeNif.__bendler_call(frame, 1000)
    end

    assert CompositePort.upper(?z) == ?Z
    assert CompositeNif.half(2.0) == 1.0
  end
end
