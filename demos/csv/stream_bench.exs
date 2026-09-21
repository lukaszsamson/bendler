# MIX_ENV=test mix run demos/csv/stream_bench.exs
# ROWS=10000,100000 SAMPLES=5 CHUNK_BYTES=16384
defmodule CsvStreamBench do
  @moduledoc false
  alias Bendler.Demos.{CsvStream, CsvStreamPort}
  alias NimbleCSV.RFC4180, as: CSV

  def run do
    counts =
      System.get_env("ROWS", "10000,100000")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    samples = System.get_env("SAMPLES", "5") |> String.to_integer()
    chunk = System.get_env("CHUNK_BYTES", "16384") |> String.to_integer()

    unless samples > 0 and Enum.all?(counts, &(&1 > 0)) and chunk in 1..65_536,
      do: raise("positive ROWS/SAMPLES and CHUNK_BYTES=1..65536 required")

    path =
      Path.join(
        System.tmp_dir!(),
        "bendler-stream-bench-#{Base.encode16(:crypto.strong_rand_bytes(12))}.csv"
      )

    {:ok, port} = CsvStreamPort.start_link(threads: 1)

    IO.puts(
      "Elixir #{System.version()}, OTP #{System.otp_release()}, #{:erlang.system_info(:system_architecture)}"
    )

    IO.puts(
      "chunk=#{chunk}B; one Bend CPU worker; samples=#{samples}; warmed medians; output reduced, not collected"
    )

    try do
      for count <- counts do
        expected = write_fixture(path, count)
        bytes = File.stat!(path).size
        source = fn -> File.stream!(path, chunk, []) end

        for backend <- [:nimble_csv, :port, :nif] do
          make = fn -> parser(source.(), backend, chunk) end
          measure(backend, make, expected, count, bytes, samples)
        end

        File.rm!(path)
      end
    after
      GenServer.stop(port)
      _ = File.rm(path)
    end
  end

  defp parser(source, :nimble_csv, _chunk),
    do: source |> CSV.to_line_stream() |> CSV.parse_stream(skip_headers: false)

  defp parser(source, backend, chunk),
    do: CsvStream.parse_stream(source, backend: backend, skip_headers: false, chunk_bytes: chunk)

  defp measure(backend, make, expected, count, bytes, samples) do
    ^expected = digest(make.())

    first =
      for _ <- 1..samples do
        {us, [row]} = :timer.tc(fn -> Enum.take(make.(), 1) end)
        if row != fields(1), do: raise("first-row mismatch")
        us / 1000
      end

    times =
      for _ <- 1..samples do
        {us, actual} = :timer.tc(fn -> digest(make.()) end)
        if actual != expected, do: raise("stream checksum mismatch")
        us / 1000
      end

    ms = median(times)

    IO.puts(
      "#{backend}: rows=#{count} bytes=#{bytes} total=#{Float.round(ms, 3)}ms first=#{Float.round(median(first), 3)}ms throughput=#{Float.round(count * 1000 / ms)} rows/s"
    )
  end

  defp fields(i), do: [Integer.to_string(i), "name#{i}", "quoted, \"value\"", "line\nżółć"]

  defp write_fixture(path, n) do
    {:ok, file} = File.open(path, [:write, :binary, :exclusive])

    try do
      Enum.reduce(1..n, {0, 0}, fn i, acc ->
        row = fields(i)
        :ok = IO.binwrite(file, CSV.dump_to_iodata([row]))
        add(row, acc)
      end)
    after
      :ok = File.close(file)
    end
  end

  defp digest(rows), do: Enum.reduce(rows, {0, 0}, &add/2)
  defp add(row, {n, hash}), do: {n + 1, Bitwise.bxor(hash, :erlang.phash2(row))}

  defp median(values) do
    sorted = Enum.sort(values)
    i = div(length(sorted), 2)

    if rem(length(sorted), 2) == 0,
      do: (Enum.at(sorted, i - 1) + Enum.at(sorted, i)) / 2,
      else: Enum.at(sorted, i)
  end
end

CsvStreamBench.run()
