defmodule Bendler.TrackThreeReviewTest do
  use ExUnit.Case, async: false
  alias Bendler.{Build, Codec, Sig}
  alias Bendler.Test.{CompositeNif, CompositePort, RecordOnlyNif, RecordOnlyPort}

  test "datatype declaration counts agree with the one-byte codec limits" do
    for n <- [255, 256, 257] do
      constructors = Enum.map_join(1..n, "\n", &"  C#{&1}{}")
      fields = Enum.map_join(1..n, ", ", &"f#{&1}: U32")

      for declaration <- [constructors, "  Fields{#{fields}}"] do
        source = "type Many is Data:\n#{declaration}\ndef echo(x: Many) -> Many:\n  x\n"
        {sigs, skipped, types} = Sig.parse(source)

        if n == 255 do
          assert length(sigs) == 1
          assert skipped == []
          table = Sig.codec_types(types)

          value =
            if declaration == constructors,
              do: :c255,
              else: List.to_tuple([:fields | List.duplicate(7, n)])

          wire = Codec.encode(value, {:data, "Many"}, table)
          assert Codec.check(Codec.reply(wire), {:data, "Many"}, :echo, table) == value
        else
          assert sigs == []
          assert types == []
          assert [{"echo", reason}] = skipped
          assert reason =~ "255"
        end
      end
    end
  end

  test "codec rejects oversized externally supplied datatype tables instead of truncating" do
    for n <- [256, 257] do
      ctors = for i <- 1..n, do: {String.to_atom("c#{i}"), []}

      for {value, table} <- [
            {elem(List.last(ctors), 0), %{"Many" => ctors}},
            {List.to_tuple([:fields | List.duplicate(0, n)]),
             %{"Many" => [fields: List.duplicate(:u32, n)]}}
          ] do
        assert_raise ArgumentError, ~r/255/, fn -> Codec.encode(value, {:data, "Many"}, table) end
      end
    end
  end

  test "Bytes inside a datatype need no unrelated Bytes export, on either backend" do
    start_supervised!({RecordOnlyPort, []})
    value = {:rec, :dot, <<0, 255, 128>>, [], :none}
    assert RecordOnlyPort.rec_echo(value) == value
    assert RecordOnlyNif.rec_echo(value) == value
  end

  test "map keys reject lossy Unicode conversion before either backend is called" do
    start_supervised!({CompositePort, []})

    for backend <- [CompositePort, CompositeNif] do
      assert_raise ArgumentError, ~r/UTF-8/, fn ->
        backend.blobs(%{<<255>> => [<<1>>], <<254>> => [<<2>>]})
      end

      value = %{"�" => [<<255>>], "" => [], "zażółć" => [<<0>>]}
      assert backend.blobs(value) == value
    end
  end

  test "build! accepts omitted options on both fresh and cached builds" do
    opts = %{
      module: RecordOnlyPort,
      app: :bendler,
      source: Path.expand("bend/composite.bend"),
      backend: :port,
      name: "review_default_build",
      exports: ["rec_echo"]
    }

    built = Build.build!(opts)
    assert Build.build!(opts) == built
    assert File.regular?(elem(built, 2))
  end
end
