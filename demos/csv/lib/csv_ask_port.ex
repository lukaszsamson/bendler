defmodule Bendler.Demos.CsvAskPort do
  @moduledoc "CSV aggregation in one native call, pulling chunks through a typed Port callback."
  use Bendler,
    otp_app: :bendler,
    source: "demos/csv/ask.bend",
    backend: :port,
    threads: 1,
    timeout: 30_000,
    exports: ["aggregate"]

  @doc "Returns {:ok, {records, fields, decoded_field_bytes}}. Includes headers as ordinary rows."
  @spec aggregate_file(Path.t(), keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def aggregate_file(path, opts \\ []) do
    chunk = Keyword.get(opts, :chunk_bytes, 16_384)
    limit = Keyword.get(opts, :max_record_bytes, 65_536)
    max_chunks = Keyword.get(opts, :max_chunks, 1_000_000)

    unless chunk in 1..65_536 and limit in 1..65_536 and max_chunks in 1..4_294_967_295,
      do: raise(ArgumentError, "invalid CSV chunk, record or request limit")

    # Non-raw IO device: callbacks run in separate processes. Raw file
    # handles must not be shared across their controlling processes.
    {:ok, file} = File.open(path, [:read, :binary])

    try do
      aggregate(chunk, limit, max_chunks, fn {offset, count} ->
        case :file.pread(file, offset, count) do
          {:ok, bytes} -> {:ok, {:some, bytes}}
          :eof -> {:ok, :none}
          {:error, reason} -> {:error, :file.format_error(reason) |> List.to_string()}
        end
      end)
    after
      File.close(file)
    end
  end
end
