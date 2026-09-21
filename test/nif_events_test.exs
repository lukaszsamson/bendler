defmodule Bendler.NifEventsTest do
  use ExUnit.Case, async: false
  alias Bendler.Test.EventsNif, as: Nif

  defp step(enum), do: Enumerable.reduce(enum, {:cont, nil}, fn x, _ -> {:suspend, x} end)

  test "pure, IO-only and plain emitter calls" do
    assert Nif.double(21) == 42
    assert Nif.tick(41) == 42
    assert Nif.count(10_000) == 1
  end

  test "stream deadlines start on enumeration, not construction" do
    stream = Bendler.Nif.stream(Nif, :count_stream, {2, [{10, :u32}], %{}, :u32, :u32}, 100)
    Process.sleep(150)
    assert Enum.take(stream, 1) == [event: 0]
    assert Nif.double(2) == 4
  end

  test "ordered scalar, tuple and datatype events end with their typed result" do
    assert Enum.to_list(Nif.count_stream(3)) == [event: 0, event: 1, event: 2, done: 3]
    assert Enum.to_list(Nif.pairs_stream(2)) == [event: {0, "0"}, event: {1, "1"}, done: 2]

    assert Enum.to_list(Nif.points_stream(2)) == [
             event: {:point, 0, 0},
             event: {:point, 1, 1},
             done: 2
           ]

    assert Enum.to_list(Nif.count_stream(0)) == [done: 0]
  end

  test "one outstanding event, early halt and no mailbox pollution" do
    {:suspended, {:event, 0}, cont} = step(Nif.count_stream(100_000))
    refute_receive {:bendler_event, _, _, _}, 50
    assert {:halted, nil} = cont.({:halt, nil})
    assert Nif.double(21) == 42
    refute_receive {:bendler_event, _, _, _}, 50
    refute_receive {:bendler_reply, _, _}, 10
  end

  test "consumer exception cancels and a repeated enumeration starts fresh" do
    stream = Nif.count_stream(3)
    assert Enum.take(stream, 1) == [event: 0]
    assert Enum.take(stream, 1) == [event: 0]
    assert_raise RuntimeError, "stop", fn -> Enum.each(stream, fn _ -> raise "stop" end) end
    assert Nif.double(2) == 4
  end

  test "caller death wakes a runtime parked in emit" do
    parent = self()

    pid =
      spawn(fn ->
        {:suspended, {:event, 0}, _} = step(Nif.count_stream(100_000))
        send(parent, :paused)
        Process.sleep(:infinity)
      end)

    assert_receive :paused
    Process.exit(pid, :kill)
    assert Nif.double(3) == 6
  end

  test "native deadline expires even while consumer is paused" do
    ref = make_ref()
    # count is export 2 in bend/events.bend after filtering helper defs.
    frame = Bendler.Codec.request(2, [{100_000, :u32}])
    {:ok, handle} = Nif.__bendler_subscribe(frame, Bendler.Nif.deadline(50), ref)
    assert_receive {:bendler_event, ^ref, 1, _}
    assert_receive {:bendler_reply, ^ref, {:error, :timeout}}, 1_000
    assert Nif.double(4) == 8
    :ok = Nif.__bendler_cancel(handle)
  end

  test "stale and duplicate acknowledgements cannot advance a later event" do
    ref = make_ref()
    frame = Bendler.Codec.request(2, [{10, :u32}])
    {:ok, handle} = Nif.__bendler_subscribe(frame, :infinity, ref)
    assert_receive {:bendler_event, ^ref, 1, _}
    :ok = Nif.__bendler_ack(handle, 0, true)
    refute_receive {:bendler_event, ^ref, _, _}, 20
    :ok = Nif.__bendler_ack(handle, 1, true)
    assert_receive {:bendler_event, ^ref, 2, _}
    :ok = Nif.__bendler_ack(handle, 1, true)
    refute_receive {:bendler_event, ^ref, _, _}, 20
    :ok = Nif.__bendler_cancel(handle)
    assert Nif.double(5) == 10
  end

  test "cancellation races leave no late messages" do
    for _ <- 1..100 do
      assert Enum.take(Nif.count_stream(100), 1) == [event: 0]
      assert Nif.double(1) == 2
    end

    refute_receive {:bendler_event, _, _, _}, 20
    refute_receive {:bendler_reply, _, _}, 20
  end

  test "paused events retain admission and queued requests can be cancelled" do
    ref = make_ref()

    {:ok, running} =
      Nif.__bendler_subscribe(Bendler.Codec.request(2, [{100, :u32}]), :infinity, ref)

    assert_receive {:bendler_event, ^ref, 1, _}
    queued_ref = make_ref()

    {:ok, queued} =
      Nif.__bendler_submit(Bendler.Codec.request(0, [{2, :u32}]), :infinity, queued_ref)

    assert {:error, :busy} =
             Nif.__bendler_submit(Bendler.Codec.request(0, [{3, :u32}]), :infinity, make_ref())

    :ok = Nif.__bendler_cancel(queued)
    :ok = Nif.__bendler_cancel(running)
    assert Nif.double(3) == 6
    refute_receive {:bendler_reply, ^queued_ref, _}, 20
  end

  test "runtime failure during a stream freezes only its module" do
    alias Bendler.Test.EventsBoomNif

    assert_raise Bendler.Error, ~r/dead/, fn ->
      EventsBoomNif.fail_after_stream(Integer.pow(2, 48) - 1) |> Enum.to_list()
    end

    assert Nif.double(21) == 42
  end
end
