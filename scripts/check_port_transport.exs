# ROUNDS=200 MIX_ENV=test mix run scripts/check_port_transport.exs
# Historical status-74 stress probe. Failure is reported, never retried away.
defmodule Bendler.PortTransportCheck do
  alias Bendler.Examples.MurmurPort
  alias Bendler.Test.{EventsPort, MurmurReference}

  def run do
    rounds = System.get_env("ROUNDS", "200") |> String.to_integer()
    unless rounds in 1..10_000, do: raise("ROUNDS must be 1..10000")

    {:ok, sup} =
      Supervisor.start_link(
        [
          {EventsPort, timeout: 5000},
          {MurmurPort, threads: 2, timeout: 5000}
        ],
        strategy: :one_for_one
      )

    try do
      # Sizes straddle the relay's 64 KiB buffer and normal pipe capacities.
      inputs =
        Enum.map([0, 1, 4095, 4096, 4097, 65_535, 65_536, 65_537], fn size ->
          :binary.copy(<<71>>, size)
        end)

      expected = Enum.map(inputs, &MurmurReference.hash_x86_32(&1, 17))

      for round <- 1..rounds do
        task = Task.async(fn -> exercise_events(round) end)
        ^expected = MurmurPort.hash_batch(inputs, 17)
        :ok = Task.await(task, 6000)
        if rem(round, 25) == 0, do: IO.puts("Port transport: #{round}/#{rounds} rounds passed")
      end

      IO.puts(
        "Port transport: #{rounds} concurrent event-cancellation/hash rounds passed; no retries"
      )
    after
      Supervisor.stop(sup)
    end
  end

  defp exercise_events(round) do
    case rem(round, 3) do
      0 ->
        count = rem(round, 7) + 1
        events = Enum.take(EventsPort.count_stream(10_000), count)
        ^count = length(events)

      1 ->
        try do
          Enum.each(EventsPort.count_stream(10_000), fn _ -> throw(:consumer_stopped) end)
        catch
          :throw, :consumer_stopped -> :ok
        end

      2 ->
        kill_consumer()
    end

    42 = EventsPort.double(21)
    :ok
  end

  defp kill_consumer do
    parent = self()

    {pid, mon} =
      spawn_monitor(fn ->
        Enum.each(EventsPort.count_stream(10_000), fn _ ->
          send(parent, {:event_ready, self()})
          Process.sleep(:infinity)
        end)
      end)

    receive do
      {:event_ready, ^pid} -> Process.exit(pid, :kill)
    after
      5000 ->
        Process.exit(pid, :kill)
        raise "consumer never received an event"
    end

    receive do
      {:DOWN, ^mon, :process, ^pid, :killed} -> :ok
    after
      1000 -> raise "consumer did not exit"
    end
  end
end

Bendler.PortTransportCheck.run()
