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

    assert_raise ArgumentError, fn -> Codec.encode(nil, {:maybe, :u32}) end
    assert_raise ArgumentError, fn -> Codec.encode({1}, {:tuple, [:u32, :u32]}) end
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
end
