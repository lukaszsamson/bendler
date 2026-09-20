defmodule Bendler.CodecBudgetTest do
  use ExUnit.Case, async: false

  alias Bendler.Codec
  alias Bendler.Sig
  alias Bendler.Test.{CompositeNif, CompositePort}

  @decoded_limit 64 * 1024 * 1024

  setup do
    start_supervised!({CompositePort, []})
    :ok
  end

  test "the Elixir request and reply codecs reject decoded-memory amplification" do
    # The runtime represents a worst-case String as one two-word cons per byte.
    string = :binary.copy(<<0xFF>>, div(@decoded_limit, 16))

    assert_raise ArgumentError, ~r/request decoded memory budget exceeded/, fn ->
      Codec.request(0, [{{1, string}, {:tuple, [:u32, :string]}}])
    end

    # decode_items temporarily holds both its placeholder and result lists.
    count = div(@decoded_limit, 32) + 1
    reply = <<6, count::32>> <> :binary.copy(<<5>>, count)

    assert_raise Bendler.Error, ~r/reply decoded memory budget exceeded/, fn ->
      Codec.reply(reply)
    end
  end

  test "both native validators reject canonical and Dyn decoded-memory amplification" do
    pair = export_index("pair")
    string = :binary.copy(<<0xFF>>, div(@decoded_limit, 16))
    canonical = <<pair::32, 8, 2, 1, 1::32, 3, byte_size(string)::32, string::binary>>
    assert_native_rejected(canonical, ~r/decoded memory budget exceeded/)

    # A List<Shape> uses 24 bytes/item for its temporary array and runtime
    # list, plus a 16-byte Dyn.DK node for every nullary Dot constructor.
    area_all = export_index("area_all")
    count = div(@decoded_limit - 8, 40) + 1
    dyn = <<area_all::32, 6, count::32>> <> :binary.copy(<<15, 2, 0>>, count)
    assert_native_rejected(dyn, ~r/decoded memory budget exceeded/)

    assert CompositePort.pair({7, "still alive"}) == {7, "still alive"}
    assert CompositeNif.area(:dot) == 0
  end

  test "deterministic truncation corpus is rejected by both native transports" do
    valid = [
      Codec.request(export_index("pair"), [{{17, "abcdef"}, {:tuple, [:u32, :string]}}]),
      Codec.request(export_index("optional"), [{{:some, {:some, 9}}, {:maybe, {:maybe, :u32}}}]),
      Codec.request(export_index("empty"), [
        {[
           :none,
           {:some, {:ok, [1, 2]}},
           {:some, {:error, {3, "bad"}}}
         ], {:list, {:maybe, {:result, {:tuple, [:u32, :string]}, {:list, :u32}}}}}
      ])
    ]

    :rand.seed(:exsss, {101, 202, 303})

    for frame <- valid, _ <- 1..24 do
      cut = :rand.uniform(byte_size(frame)) - 1
      assert_native_rejected(binary_part(frame, 0, cut))
    end

    assert CompositePort.optional(:none) == :none
    assert CompositeNif.pair({1, "ok"}) == {1, "ok"}
  end

  test "deterministic reply fuzz covers truncation, count lies and nesting" do
    :rand.seed(:exsss, {404, 505, 606})

    for _ <- 1..200 do
      text = for _ <- 1..:rand.uniform(24), into: <<>>, do: <<:rand.uniform(256) - 1>>
      values = Enum.map(1..:rand.uniform(8), fn _ -> :rand.uniform(4_294_967_296) - 1 end)
      value = {text, values}
      frame = Codec.encode(value, {:tuple, [:bytes, {:list, :u32}]})
      cut = :rand.uniform(byte_size(frame)) - 1

      assert_raise Bendler.Error, fn -> Codec.reply(binary_part(frame, 0, cut)) end
    end

    for frame <- [
          <<6, 2::32, 5>>,
          <<8, 2, 5>>,
          <<15, 0, 2, 5>>,
          <<3, 100::32, "short">>,
          <<7, 0xFFFFFFFF::32>>
        ] do
      assert_raise Bendler.Error, fn -> Codec.reply(frame) end
    end

    too_deep = :binary.copy(<<10>>, 2049) <> <<9>>
    assert_raise Bendler.Error, ~r/nested too deep/, fn -> Codec.reply(too_deep) end
  end

  test "recursive datatype nesting is refused by both native transports" do
    lst_len = export_index("lst_len")
    # LCons{U32, Lst} repeated past BL_MAX_DEPTH, terminated by LNil{}.
    cell = <<15, 1, 2, 1, 0::32>>
    frame = <<lst_len::32>> <> :binary.copy(cell, 2049) <> <<15, 0, 0>>
    assert_native_rejected(frame, ~r/nested too deep/)
  end

  test "Map keys must be valid UTF-8 before request construction" do
    assert_raise ArgumentError, ~r/valid UTF-8/, fn ->
      Codec.request(0, [{%{<<0xFF>> => 1}, {:map, :u32}}])
    end
  end

  test "port rejects an oversized frame header without reading its announced payload" do
    exe = Bendler.Build.artifact_path(:bendler, "bendler_test_composite_port", :port)
    launcher = Bendler.Build.launcher_path(:bendler, "bendler_test_composite_port")

    port =
      Port.open({:spawn_executable, launcher}, [
        :binary,
        :exit_status,
        args: [exe, "--threads", "1", "--gpu", "off"]
      ])

    try do
      assert Port.command(port, <<@decoded_limit + 1::32>>)
      assert_receive {^port, {:exit_status, 65}}, 3000
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  test "NIF rejects an oversized request before decoding and stays usable" do
    frame = :binary.copy(<<0>>, @decoded_limit + 1)
    assert {:error, {:invalid, reason}} = CompositeNif.__bendler_call(frame, 2000)
    assert to_string(reason) =~ "BENDLER_MAX_FRAME"
    assert CompositeNif.optional(:none) == :none
  end

  defp export_index(name) do
    {sigs, _, _} = Sig.parse(File.read!("bend/composite.bend"))
    Enum.find_index(sigs, &(&1.name == name))
  end

  defp assert_native_rejected(frame, message \\ ~r/.+/) do
    assert_raise Bendler.Error, message, fn ->
      CompositePort |> Bendler.Port.call(frame) |> Codec.reply()
    end

    assert {:error, {:invalid, reason}} = CompositeNif.__bendler_call(frame, 2_000)
    assert to_string(reason) =~ message
  end
end
