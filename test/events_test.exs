defmodule Bendler.EventsTest do
  use ExUnit.Case, async: false
  alias Bendler.Test.{EventsDeadlinePort, EventsPort}

  setup do
    start_supervised!({EventsPort, []})
    :ok
  end

  # Drives a stream one element at a time in the calling process, so the
  # events and the acknowledgements are visible to the test's mailbox.
  defp step(enum_or_cont)

  defp step(fun) when is_function(fun, 1), do: reduced(fun.({:cont, nil}))

  defp step(enum),
    do: reduced(Enumerable.reduce(enum, {:cont, nil}, fn x, _ -> {:suspend, x} end))

  defp reduced({:suspended, value, cont}), do: {value, cont}
  defp reduced({:done, value}), do: {:done_stream, value}

  defp stop(cont), do: cont.({:halt, nil})

  test "a pure export is unaffected" do
    assert EventsPort.double(21) == 42
  end

  test "halting after owner replacement monitors the original owner" do
    {_, cont} = step(EventsPort.count_stream(10))
    old = Process.whereis(EventsPort)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, _}
    # A supervisor restart need not have happened yet: deliberately ensure
    # the name is now bound to a different owner before releasing.
    wait_replacement(old, 100)
    assert {:halted, nil} = stop(cont)
    assert EventsPort.double(4) == 8
  end

  defp wait_replacement(_, 0), do: flunk("owner did not restart")

  defp wait_replacement(old, n) do
    case Process.whereis(EventsPort) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ ->
        Process.sleep(10)
        wait_replacement(old, n - 1)
    end
  end

  test "generated stream names cannot shadow exports" do
    assert_raise Bendler.Error, ~r/foo_stream/, fn ->
      Bendler.Sig.parse(
        "def foo(~emit: U32 -> IO(Bool), n: U32) -> IO(U32):\n  x\ndef foo_stream(n: U32) -> U32:\n  n"
      )
    end
  end

  test "an effectful export with no events is an ordinary call" do
    assert EventsPort.tick(41) == 42
  end

  test "events arrive in order, decoded and checked, and the stream ends with the result" do
    assert Enum.to_list(EventsPort.count_stream(5)) ==
             [event: 0, event: 1, event: 2, event: 3, event: 4, done: 5]
  end

  test "a datatype-typed event crosses as its tagged tuple" do
    assert Enum.to_list(EventsPort.points_stream(3)) ==
             [event: {:point, 0, 0}, event: {:point, 1, 1}, event: {:point, 2, 4}, done: 3]
  end

  test "a product-typed event crosses as its tuple" do
    assert Enum.to_list(EventsPort.pairs_stream(3)) ==
             [event: {0, "0"}, event: {1, "1"}, event: {2, "2"}, done: 3]
  end

  test "a corrupt event frame raises Bendler.Error rather than yielding a value" do
    assert_raise Bendler.Error, ~r/malformed reply/, fn ->
      Bendler.Codec.event(<<200, 1, 2>>, :u32, :count_stream)
    end

    assert_raise Bendler.Error, ~r/trailing bytes in an event/, fn ->
      Bendler.Codec.event(<<1, 0, 0, 0, 7, 99>>, :u32, :count_stream)
    end

    assert_raise Bendler.Error, ~r/is not a/, fn ->
      Bendler.Codec.event(<<3, 0, 0, 0, 1, ?x>>, :u32, :count_stream)
    end
  end

  test "a paused consumer holds one event and the worker waits for its acknowledgement" do
    {first, cont} = step(EventsPort.count_stream(64))
    assert first == {:event, 0}

    # the worker is parked inside its emit: nothing else arrives
    refute_receive {:bendler_event, _, _}, 250

    {second, cont} = step(cont)
    assert second == {:event, 1}
    refute_receive {:bendler_event, _, _}, 100

    stop(cont)
    assert EventsPort.double(4) == 8
  end

  test "halting early makes the next emit answer False and the def finish early" do
    assert EventsPort.count_stream(10_000) |> Enum.take(3) == [event: 0, event: 1, event: 2]
    # the def stopped at the refused third event and the port is free again
    assert Enum.to_list(EventsPort.count_stream(2)) == [event: 0, event: 1, done: 2]
  end

  test "an exception in the consumer releases the request too" do
    assert_raise RuntimeError, "boom", fn ->
      Enum.each(EventsPort.count_stream(10_000), fn _ -> raise "boom" end)
    end

    assert EventsPort.double(5) == 10
  end

  test "the plain call of an emitter export refuses its events at once" do
    # the first emit is answered False, so the def stops having emitted one
    assert EventsPort.count(10_000) == 1
    assert EventsPort.double(6) == 12
  end

  test "a consumer that dies mid-stream frees the request" do
    parent = self()

    pid =
      spawn(fn ->
        {first, _cont} = step(EventsPort.count_stream(10_000))
        send(parent, {:got, first})
        Process.sleep(:infinity)
      end)

    assert_receive {:got, {:event, 0}}, 5_000
    Process.exit(pid, :kill)

    # the owner answers False for the dead subscriber and drops the reply
    assert EventsPort.double(7) == 14
  end

  test "the deadline fires while the worker waits on an acknowledgement" do
    start_supervised!({EventsDeadlinePort, []})
    {first, cont} = step(EventsDeadlinePort.count_stream(10_000))
    assert first == {:event, 0}
    Process.sleep(500)

    assert_raise Bendler.Error, fn -> step(cont) end
  end

  test "port death mid-stream raises in the consumer" do
    {first, cont} = step(EventsPort.count_stream(10_000))
    assert first == {:event, 0}
    Process.exit(Process.whereis(EventsPort), :kill)

    assert_raise Bendler.Error, ~r/exited/, fn -> step(cont) end
  end

  test "an effectful export is refused at build time under the NIF backend" do
    assert_raise Bendler.Error, ~r/needs the :port backend/, fn ->
      defmodule EventsNifRefused do
        use Bendler,
          otp_app: :bendler,
          source: "bend/events.bend",
          backend: :nif,
          exports: ["count"]
      end
    end
  end
end
