# MIX_ENV=test mix run demos/sorting/bench.exs
# SIZES=256,4096,32768 SAMPLES=5 THREADS=1,4,12
# SHAPES=random,sorted,reversed,duplicates
defmodule SortingBench do
  @moduledoc false
  alias Bendler.Demos.SortingPort

  def measure(label, expected, samples, fun) do
    if fun.() != expected, do: raise("warmup result mismatch: #{label}")

    times =
      for _ <- 1..samples do
        {us, result} = :timer.tc(fun)
        if result != expected, do: raise("timed result mismatch: #{label}")
        us / 1000
      end
      |> Enum.sort()

    middle = div(samples, 2)

    median =
      if rem(samples, 2) == 0,
        do: (Enum.at(times, middle - 1) + Enum.at(times, middle)) / 2,
        else: Enum.at(times, middle)

    IO.puts(
      "#{label}: median=#{Float.round(median, 3)} min=#{Float.round(hd(times), 3)} max=#{Float.round(List.last(times), 3)} ms nout=#{length(expected)}"
    )
  end

  def numbers(key, default) do
    values = System.get_env(key, default) |> String.split(",") |> Enum.map(&String.to_integer/1)
    unless Enum.all?(values, &(&1 > 0)), do: raise("#{key} must contain positive integers")
    values
  end

  def data(n, shape) do
    :rand.seed(:exsss, {23, n, 97})
    xs = for _ <- 1..n, do: :rand.uniform(4_294_967_296) - 1

    case shape do
      "random" -> xs
      "sorted" -> Enum.sort(xs)
      "reversed" -> Enum.sort(xs, :desc)
      "duplicates" -> Enum.map(xs, &rem(&1, 64))
      _ -> raise("unknown SHAPES entry #{shape}")
    end
  end

  def sets(n) do
    :rand.seed(:exsss, {71, n, 39})
    a = for _ <- 1..n, do: :rand.uniform(n) - 1
    b = for _ <- 1..n, do: :rand.uniform(n) - 1

    for op <- [:union, :intersection, :difference] do
      expected = reference(op, a, b)
      {op, a, b, expected}
    end
  end

  def reference(op, a, b), do: MapSet |> apply(op, [MapSet.new(a), MapSet.new(b)]) |> Enum.sort()

  def run do
    sizes = numbers("SIZES", "256,4096,32768")
    threads = numbers("THREADS", "1,4,#{System.schedulers_online()}") |> Enum.uniq()
    [samples] = numbers("SAMPLES", "5")
    shapes = System.get_env("SHAPES", "random,sorted,reversed,duplicates") |> String.split(",")

    IO.puts(
      "Elixir #{System.version()} OTP #{System.otp_release()} #{:erlang.system_info(:system_architecture)}"
    )

    IO.puts(
      "warm samples=#{samples}; sizes=#{inspect(sizes)}; threads=#{inspect(threads)}; CPU only"
    )

    cases = for n <- sizes, shape <- shapes, do: {n, shape, data(n, shape)}
    sets = sets(Enum.max(sizes))

    for {n, shape, xs} <- cases do
      measure("Enum.sort n=#{n} #{shape}", Enum.sort(xs), samples, fn -> Enum.sort(xs) end)
    end

    for {op, a, b, expected} <- sets do
      measure("MapSet+sort #{op} n=#{length(a)} each", expected, samples, fn ->
        reference(op, a, b)
      end)
    end

    for t <- threads do
      {:ok, pid} = SortingPort.start_link(threads: t)

      try do
        for n <- sizes do
          xs = data(n, "random")
          measure("identity threads=#{t} n=#{n}", xs, samples, fn -> SortingPort.identity(xs) end)
        end

        for {n, shape, xs} <- cases do
          measure("bitonic threads=#{t} n=#{n} #{shape}", Enum.sort(xs), samples, fn ->
            SortingPort.sort(xs)
          end)
        end

        for {op, a, b, expected} <- sets do
          measure("bend #{op} threads=#{t} n=#{length(a)} each", expected, samples, fn ->
            apply(SortingPort, op, [a, b])
          end)
        end
      after
        GenServer.stop(pid)
      end
    end
  end
end

SortingBench.run()
