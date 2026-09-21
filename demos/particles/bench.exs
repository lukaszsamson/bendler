# N=64 TICKS=2000 SAMPLES=5 MIX_ENV=test mix run demos/particles/bench.exs
defmodule ParticleBench do
  @moduledoc false
  alias Bendler.Demos.{Particles, ParticlesNif, ParticlesPort}

  def run do
    n = integer("N", 64)
    ticks = integer("TICKS", 2000)
    samples = integer("SAMPLES", 5)
    cloud = Particles.cloud(n)
    {:ok, owner} = ParticlesPort.start_link()

    IO.puts(
      "Elixir #{System.version()}, OTP #{System.otp_release()}, #{:erlang.system_info(:system_architecture)}"
    )

    IO.puts(
      "#{n} particles; #{ticks} ticks; #{samples} warmed samples; 2 Bend CPU workers; no file IO"
    )

    try do
      for kind <- [:pulse, :particles] do
        expected = consume(stream(ParticlesPort, kind, cloud, ticks))

        for module <- [ParticlesPort, ParticlesNif] do
          measure(module, kind, cloud, ticks, samples, expected)
        end
      end
    after
      GenServer.stop(owner)
    end
  end

  defp integer(name, default) do
    value = System.get_env(name, to_string(default)) |> String.to_integer()
    if value < 1, do: raise("#{name} must be positive")
    value
  end

  defp stream(module, :pulse, _, ticks), do: module.pulse_stream(ticks)
  defp stream(module, :particles, cloud, ticks), do: module.simulate_stream(cloud, ticks, 0.01)

  defp consume(stream) do
    Enum.reduce(stream, {0, 0, nil}, fn
      {:event, value}, {n, sum, done} -> {n + 1, Bitwise.bxor(sum, :erlang.phash2(value)), done}
      {:done, result}, {n, sum, _} -> {n, sum, result}
    end)
  end

  defp measure(module, kind, cloud, ticks, samples, expected) do
    make = fn -> stream(module, kind, cloud, ticks) end
    if consume(make.()) != expected, do: raise("backend mismatch")

    totals =
      for _ <- 1..samples do
        {us, result} = :timer.tc(fn -> consume(make.()) end)
        if result != expected, do: raise("backend mismatch")
        us
      end

    latencies =
      for _ <- 1..samples do
        started = System.monotonic_time(:microsecond)

        {:suspended, {:event, _}, cont} =
          Enumerable.reduce(make.(), {:cont, nil}, fn x, _ -> {:suspend, x} end)

        first = System.monotonic_time(:microsecond) - started
        cancelled = System.monotonic_time(:microsecond)
        {:halted, nil} = cont.({:halt, nil})
        # Barrier: includes cooperative native completion, not just API return.
        module.positions(cloud)
        {first, System.monotonic_time(:microsecond) - cancelled}
      end

    total = median(totals)
    first = latencies |> Enum.map(&elem(&1, 0)) |> median()
    cancel = latencies |> Enum.map(&elem(&1, 1)) |> median()

    IO.puts(
      "#{kind} #{inspect(module)} total=#{Float.round(total / 1000, 3)}ms avg=#{Float.round(total / ticks, 2)}us/event first=#{first}us cancel+barrier=#{cancel}us"
    )
  end

  defp median(xs) do
    sorted = Enum.sort(xs)
    (Enum.at(sorted, div(length(xs) - 1, 2)) + Enum.at(sorted, div(length(xs), 2))) / 2
  end
end

ParticleBench.run()
