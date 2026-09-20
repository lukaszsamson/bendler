# MIX_ENV=test mix run demos/mandelbrot/bench.exs
# Optional: DEPTHS=2,8,12 ITERATIONS=31 SAMPLES=5 THREADS=1,4,12
Code.require_file("bench_support.exs", __DIR__)
alias Bendler.Demos.{MandelbrotPort, MandelbrotReference}
MandelbrotBench.environment()

threads =
  System.get_env(
    "THREADS",
    "1,#{min(4, System.schedulers_online())},#{System.schedulers_online()}"
  )
  |> String.split(",")
  |> Enum.map(&String.to_integer/1)
  |> Enum.uniq()

cases =
  for {depth, iterations, count} <- MandelbrotBench.cases() do
    expected = MandelbrotReference.checksum(depth, iterations)

    MandelbrotBench.measure("elixir pixels=#{count} iterations=#{iterations}", expected, fn ->
      MandelbrotReference.checksum(depth, iterations)
    end)

    {depth, iterations, count, expected}
  end

for n <- threads do
  {:ok, pid} = MandelbrotPort.start_link(threads: n)

  try do
    for {depth, iterations, count, expected} <- cases do
      MandelbrotBench.measure(
        "bend-port threads=#{n} pixels=#{count} iterations=#{iterations}",
        expected,
        fn ->
          MandelbrotPort.checksum(depth, iterations)
        end
      )
    end
  after
    GenServer.stop(pid)
  end
end
