# MIX_ENV=test mix run demos/csv/bench.exs
# ROWS=10,1000,10000 SAMPLES=5
defmodule CsvBench do
  @moduledoc false
  alias Bendler.Demos.CsvPort
  alias NimbleCSV.RFC4180, as: CSV

  def measure(label, expected, samples, fun) do
    if fun.() != expected, do: raise("warmup mismatch: #{label}")

    times =
      for _ <- 1..samples do
        {us, value} = :timer.tc(fun)
        if value != expected, do: raise("timed result mismatch: #{label}")
        us / 1000
      end
      |> Enum.sort()

    middle = div(samples, 2)

    median =
      if rem(samples, 2) == 0,
        do: (Enum.at(times, middle - 1) + Enum.at(times, middle)) / 2,
        else: Enum.at(times, middle)

    IO.puts(
      "#{label}: median=#{Float.round(median, 3)} min=#{Float.round(hd(times), 3)} max=#{Float.round(List.last(times), 3)} ms"
    )
  end

  def run do
    counts =
      System.get_env("ROWS", "10,1000,10000")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    samples = System.get_env("SAMPLES", "5") |> String.to_integer()

    unless samples > 0 and Enum.all?(counts, &(&1 > 0)),
      do: raise("ROWS and SAMPLES must be positive")

    IO.puts(
      "Elixir #{System.version()} OTP #{System.otp_release()} #{:erlang.system_info(:system_architecture)}; NimbleCSV 1.3.0; Bend CPU threads=1; samples=#{samples}"
    )

    {:ok, pid} = CsvPort.start_link(threads: 1)

    try do
      for n <- counts, shape <- [:plain, :quoted] do
        rows =
          for i <- 1..n do
            if shape == :plain,
              do: [Integer.to_string(i), "name#{i}", "value", "end"],
              else: [Integer.to_string(i), "name, #{i}", "line\n\"quoted\"", "zażółć"]
          end

        data = rows |> CSV.dump_to_iodata() |> IO.iodata_to_binary()
        label = "rows=#{n} #{shape} input=#{byte_size(data)}B"

        measure("NimbleCSV #{label}", rows, samples, fn ->
          CSV.parse_string(data, skip_headers: false)
        end)

        measure("Bend Port #{label}", {:ok, rows}, samples, fn ->
          CsvPort.parse_string(data, skip_headers: false)
        end)
      end
    after
      GenServer.stop(pid)
    end
  end
end

CsvBench.run()
