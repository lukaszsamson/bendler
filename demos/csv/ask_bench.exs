# ROWS=10000,100000 SAMPLES=5 MIX_ENV=test mix run demos/csv/ask_bench.exs
defmodule CsvAskBench do
  @moduledoc false
  alias Bendler.Demos.{CsvAskPort, CsvStream, CsvStreamPort}

  def run do
    counts =
      System.get_env("ROWS", "10000,100000")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    samples = System.get_env("SAMPLES", "5") |> String.to_integer()
    chunk = System.get_env("CHUNK_BYTES", "16384") |> String.to_integer()

    unless samples > 0 and chunk in 1..65_536 and Enum.all?(counts, &(&1 > 0)),
      do: raise("invalid benchmark size")

    {:ok, sup} = Supervisor.start_link([CsvAskPort, CsvStreamPort], strategy: :one_for_one)

    path =
      Path.join(
        System.tmp_dir!(),
        "bendler_ask_bench_#{Base.encode16(:crypto.strong_rand_bytes(12))}.csv"
      )

    IO.puts(
      "Elixir #{System.version()}, OTP #{System.otp_release()}, #{:erlang.system_info(:system_architecture)}"
    )

    IO.puts(
      "Warmed median; #{samples} samples; #{chunk}-byte chunks; one CPU worker; file IO included"
    )

    try do
      for count <- counts do
        File.open!(path, [:write, :exclusive], fn file ->
          for i <- 1..count, do: IO.binwrite(file, "#{i},\"quoted, value\",\"line\nżółć\"\n")
        end)

        nimble = fn ->
          path
          |> File.stream!(chunk, [])
          |> NimbleCSV.RFC4180.to_line_stream()
          |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
          |> totals()
        end

        host = fn ->
          path
          |> File.stream!(chunk, [])
          |> CsvStream.parse_stream(skip_headers: false, chunk_bytes: chunk)
          |> totals()
        end

        native = fn ->
          {:ok, value} = CsvAskPort.aggregate_file(path, chunk_bytes: chunk)
          value
        end

        expected = nimble.()

        IO.puts(
          "rows=#{count} bytes=#{File.stat!(path).size} asks=#{div(File.stat!(path).size + chunk - 1, chunk) + 1}"
        )

        for {name, fun} <- [nimble_csv: nimble, host_driven_port: host, ask_port: native] do
          measure(name, fun, expected, samples)
        end

        File.rm!(path)
      end
    after
      Supervisor.stop(sup)
      File.rm(path)
    end
  end

  defp measure(name, fun, expected, samples) do
    if fun.() != expected, do: raise("aggregate mismatch for #{name}")

    times =
      for _ <- 1..samples do
        {us, result} = :timer.tc(fun)
        if result != expected, do: raise("aggregate mismatch for #{name}")
        us / 1000
      end

    sorted = Enum.sort(times)
    median = (Enum.at(sorted, div(samples - 1, 2)) + Enum.at(sorted, div(samples, 2))) / 2
    IO.puts("#{name}: #{Float.round(median, 3)} ms")
  end

  defp totals(rows) do
    Enum.reduce(rows, {0, 0, 0}, fn row, {r, f, b} ->
      {r + 1, f + length(row), b + Enum.reduce(row, 0, &(byte_size(&1) + &2))}
    end)
  end
end

CsvAskBench.run()
