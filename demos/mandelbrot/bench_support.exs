defmodule MandelbrotBench do
  @moduledoc false
  import Bitwise

  def cases do
    depths =
      System.get_env("DEPTHS", "2,8,12") |> String.split(",") |> Enum.map(&String.to_integer/1)

    iterations = String.to_integer(System.get_env("ITERATIONS", "31"))
    for depth <- depths, do: {depth, iterations, 64 <<< depth}
  end

  def measure(label, expected, fun) do
    samples = String.to_integer(System.get_env("SAMPLES", "5"))
    if samples < 1, do: raise(ArgumentError, "SAMPLES must be positive")
    {cold, result} = :timer.tc(fun)

    if result != expected,
      do: raise("#{label}: incorrect checksum #{inspect(result)} != #{expected}")

    times =
      for _ <- 1..samples do
        {us, result} = :timer.tc(fun)
        if result != expected, do: raise("#{label}: incorrect timed result")
        us / 1000
      end
      |> Enum.sort()

    IO.puts(
      "#{label}: median=#{Float.round(Enum.at(times, div(samples, 2)), 3)} ms " <>
        "min=#{Float.round(hd(times), 3)} max=#{Float.round(List.last(times), 3)} " <>
        "cold=#{Float.round(cold / 1000, 3)} ms samples=#{samples} checksum=#{expected}"
    )
  end

  def environment do
    IO.puts(
      "Elixir #{System.version()} OTP #{System.otp_release()} #{:erlang.system_info(:system_architecture)}"
    )

    IO.puts("BEAM schedulers=#{System.schedulers_online()}; cases=#{inspect(cases())}")
  end
end
