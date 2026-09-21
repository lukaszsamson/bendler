defmodule Bendler.NifAsyncTest do
  use ExUnit.Case, async: false

  alias Bendler.{Codec, Sig}
  alias Bendler.Examples.FibNif
  alias Bendler.Test.QueueNif

  @slow_n 28

  test "long finite deadlines do not exceed the BEAM receive timeout range" do
    assert 55 ==
             Codec.reply(FibNif.__bendler_call(frame(FibNif, "fib", [10, 0, 1]), 5_000_000_000))
  end

  test "a generated NIF call charges encoding time to its total deadline" do
    caller = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:bendler, :call, :start],
        fn _event, _measurements, metadata, expected_caller ->
          if self() == expected_caller and metadata.module == QueueNif and
               metadata.function == :fib do
            Process.sleep(200)
          end
        end,
        caller
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    error = assert_raise Bendler.Error, fn -> QueueNif.fib(10, 0, 1) end
    assert error.reason == :timeout

    :telemetry.detach(handler_id)
    assert QueueNif.fib(10, 0, 1) == 55
  end

  test "an already-expired asynchronous deadline is refused without a reply or work" do
    ref = make_ref()

    assert {:error, :timeout} =
             QueueNif.__bendler_submit(
               frame(QueueNif, "slow", [@slow_n]),
               System.monotonic_time(:millisecond) - 1,
               ref
             )

    refute_receive {:bendler_reply, ^ref, _}, 100

    # A successful synchronous call on this same runtime establishes that the
    # expired frame was not retained in its mailbox.
    assert 55 ==
             Codec.reply(QueueNif.__bendler_call(frame(QueueNif, "fib", [10, 0, 1]), 5_000), :fib)
  end

  test "asynchronous submission preserves its reference and the synchronous wrapper remains available" do
    ref = make_ref()

    assert {:ok, _handle} =
             FibNif.__bendler_submit(frame(FibNif, "fib", [10, 0, 1]), :infinity, ref)

    assert_receive {:bendler_reply, ^ref, reply}, 5_000
    assert 55 == Codec.reply(reply, :fib)

    assert 6765 ==
             Codec.reply(FibNif.__bendler_call(frame(FibNif, "fib", [20, 0, 1]), 5_000), :fib)
  end

  test "cancelling queued work frees its admission slot and sends no later reply" do
    active_ref = make_ref()
    cancelled_ref = make_ref()
    replacement_ref = make_ref()
    overflow_ref = make_ref()

    # QueueNif admits two calls total. `slow/1` is deliberately long enough
    # that the second submission remains queued while this sequence runs.
    assert {:ok, _active} =
             QueueNif.__bendler_submit(frame(QueueNif, "slow", [@slow_n]), :infinity, active_ref)

    assert {:ok, cancelled} =
             QueueNif.__bendler_submit(
               frame(QueueNif, "slow", [@slow_n]),
               :infinity,
               cancelled_ref
             )

    assert {:error, :busy} =
             QueueNif.__bendler_submit(
               frame(QueueNif, "fib", [10, 0, 1]),
               :infinity,
               overflow_ref
             )

    assert :ok = QueueNif.__bendler_cancel(cancelled)

    assert {:ok, replacement} =
             QueueNif.__bendler_submit(
               frame(QueueNif, "slow", [@slow_n]),
               :infinity,
               replacement_ref
             )

    # The replacement consumes the released admission slot, so capacity is
    # still bounded even after cancellation.
    assert {:error, :busy} =
             QueueNif.__bendler_submit(
               frame(QueueNif, "fib", [10, 0, 1]),
               :infinity,
               overflow_ref
             )

    assert :ok = QueueNif.__bendler_cancel(replacement)

    # The cancellation contract is temporal: a reply delivered before it
    # returns is irrelevant, but none may arrive afterwards.
    drain_reply(cancelled_ref)
    drain_reply(replacement_ref)
    assert_receive {:bendler_reply, ^active_ref, reply}, 15_000
    assert 268_435_456 == Codec.reply(reply, :slow)
    refute_receive {:bendler_reply, ^cancelled_ref, _}, 250
    refute_receive {:bendler_reply, ^replacement_ref, _}, 250
  end

  test "cancelling active work does not release its slot before Bend finishes it" do
    active_ref = make_ref()
    pending_ref = make_ref()
    overflow_ref = make_ref()

    assert {:ok, active} =
             QueueNif.__bendler_submit(frame(QueueNif, "slow", [@slow_n]), :infinity, active_ref)

    # Cancellation suppresses delivery; it is not hard cancellation of the
    # Bend computation. There is no state-inspection API, so this merely gives
    # the loop an opportunity to claim the first request before cancellation.
    Process.sleep(20)
    assert :ok = QueueNif.__bendler_cancel(active)

    assert {:ok, pending} =
             QueueNif.__bendler_submit(frame(QueueNif, "slow", [@slow_n]), :infinity, pending_ref)

    assert {:error, :busy} =
             QueueNif.__bendler_submit(
               frame(QueueNif, "fib", [10, 0, 1]),
               :infinity,
               overflow_ref
             )

    assert :ok = QueueNif.__bendler_cancel(pending)
    assert 55 == eventually_fib()
    refute_receive {:bendler_reply, ^active_ref, _}, 250
    refute_receive {:bendler_reply, ^pending_ref, _}, 250
  end

  test "a dead submitting process releases a queued slot" do
    parent = self()
    active_ref = make_ref()
    child_ref = make_ref()

    assert {:ok, _active} =
             QueueNif.__bendler_submit(frame(QueueNif, "slow", [@slow_n]), :infinity, active_ref)

    owner =
      spawn(fn ->
        result =
          QueueNif.__bendler_submit(frame(QueueNif, "slow", [@slow_n]), :infinity, child_ref)

        send(parent, {:child_submitted, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:child_submitted, {:ok, _handle}}, 1_000
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000

    # Monitor delivery into the native queue is asynchronous. It must remove
    # the dead owner's queued work while the first slow call keeps the only
    # execution lane occupied.
    replacement_ref = make_ref()

    assert {:ok, replacement} =
             eventually_submit(frame(QueueNif, "slow", [@slow_n]), replacement_ref)

    assert :ok = QueueNif.__bendler_cancel(replacement)

    assert_receive {:bendler_reply, ^active_ref, reply}, 15_000
    assert 268_435_456 == Codec.reply(reply, :slow)
    refute_receive {:bendler_reply, ^child_ref, _}, 250
    refute_receive {:bendler_reply, ^replacement_ref, _}, 250
  end

  defp eventually_submit(frame, ref, tries \\ 50)

  defp eventually_submit(_frame, _ref, 0), do: {:error, :busy}

  defp eventually_submit(frame, ref, tries) do
    case QueueNif.__bendler_submit(frame, :infinity, ref) do
      {:error, :busy} ->
        Process.sleep(10)
        eventually_submit(frame, ref, tries - 1)

      result ->
        result
    end
  end

  defp eventually_fib(tries \\ 100)

  defp eventually_fib(0), do: flunk("the cancelled Bend work never released its slot")

  defp eventually_fib(tries) do
    QueueNif.fib(10, 0, 1)
  rescue
    error in Bendler.Error ->
      if error.reason in [:busy, :timeout] do
        Process.sleep(20)
        eventually_fib(tries - 1)
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp drain_reply(ref) do
    receive do
      {:bendler_reply, ^ref, _} -> drain_reply(ref)
    after
      0 -> :ok
    end
  end

  defp frame(module, name, args) do
    {sigs, _, _} = Sig.parse(File.read!("bend/fib.bend"))
    sigs = if module == QueueNif, do: Enum.filter(sigs, &(&1.name in ["fib", "slow"])), else: sigs
    index = Enum.find_index(sigs, &(&1.name == name))
    sig = Enum.at(sigs, index)
    Codec.request(index, Enum.zip(args, Enum.map(sig.params, & &1.type)))
  end
end
