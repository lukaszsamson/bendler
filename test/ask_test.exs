defmodule Bendler.AskTest do
  use ExUnit.Case, async: false
  alias Bendler.Test.AskPort

  setup do
    start_supervised!(AskPort)
    :ok
  end

  test "typed callbacks and sequential asks retain native state" do
    assert AskPort.once(7, fn 7 -> {:some, 42} end) == {:some, 42}
    assert AskPort.once(7, fn 7 -> :none end) == :none
    assert AskPort.pull(100, fn sum -> if sum < 10, do: {:some, 1}, else: :none end) == 10
  end

  test "handler exceptions and bad reply types refuse the call" do
    assert_raise Bendler.Error, ~r/callback/, fn -> AskPort.once(1, fn _ -> raise "oops" end) end
  end

  test "invalid returned values are rejected" do
    assert_raise Bendler.Error, ~r/callback/, fn -> AskPort.once(1, fn _ -> {:some, -1} end) end
  end

  @tag timeout: 8_000
  test "handler has its own deadline even with an infinite request deadline" do
    stop_supervised(AskPort)
    start_supervised!({AskPort, timeout: :infinity})

    assert_raise Bendler.Error, ~r/callback/, fn ->
      AskPort.once(1, fn _ -> Process.sleep(:infinity) end)
    end
  end

  test "direct reentry is rejected instead of waiting on the same worker" do
    assert AskPort.once(1, fn _ ->
             error = assert_raise Bendler.Error, fn -> AskPort.once(2, fn _ -> :none end) end
             assert error.reason == :reentrant
             :none
           end) == :none
  end

  test "total deadline kills a blocked handler" do
    stop_supervised(AskPort)
    start_supervised!({AskPort, timeout: 50})
    parent = self()

    assert_raise Bendler.Error, ~r/timeout/, fn ->
      AskPort.once(1, fn _ ->
        send(parent, {:handler, self()})
        Process.sleep(:infinity)
      end)
    end

    assert_receive {:handler, pid}
    mon = Process.monitor(pid)
    assert_receive {:DOWN, ^mon, :process, ^pid, _}
  end

  test "caller death cancels its callback and restarts the occupied worker" do
    parent = self()

    caller =
      spawn(fn ->
        AskPort.once(1, fn _ ->
          send(parent, {:handler, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:handler, handler}
    ref = Process.monitor(handler)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^handler, _}
  end

  test "brutal owner death does not orphan a blocked callback" do
    parent = self()

    task =
      Task.async(fn ->
        try do
          AskPort.once(1, fn _ ->
            send(parent, {:handler, self()})
            Process.sleep(:infinity)
          end)
        rescue
          e in Bendler.Error -> e.reason
        end
      end)

    assert_receive {:handler, handler}
    ref = Process.monitor(handler)
    Process.exit(Process.whereis(AskPort), :kill)
    assert_receive {:DOWN, ^ref, :process, ^handler, _}
    assert Task.await(task) == :exited
  end

  test "native validation rejects a malformed callback reply before decoding" do
    # pull is export zero. This intentionally bypasses the typed wrapper.
    frame = Bendler.Codec.request(0, [{1, :u32}])
    assert Bendler.Port.ask_call(AskPort, frame, fn _ -> <<10, 1>> end) == {:error, :exited}
  end
end
