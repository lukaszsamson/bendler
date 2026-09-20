defmodule Bendler.Demos.CsvPort do
  @moduledoc """
  Small byte-preserving CSV parser, compared with NimbleCSV.RFC4180.
  `parse_csv/2` returns a Result containing `{rows, row_count}` or
  `{:error, {code, byte_offset, message}}`. Separator is `:none` (comma)
  or `{:some, byte}`. `parse_string/2` is the bounded convenience wrapper.
  """
  use Bendler,
    otp_app: :bendler,
    source: "demos/csv/csv.bend",
    backend: :port,
    threads: 1,
    exports: ["parse_csv"]

  @type parse_error :: {non_neg_integer(), non_neg_integer(), String.t()}
  @doc "Parses at most 1 MiB; defaults to skipping the first row like NimbleCSV."
  @spec parse_string(binary(), keyword()) :: {:ok, [[binary()]]} | {:error, parse_error()}
  def parse_string(data, opts \\ [])

  def parse_string(data, opts) when is_binary(data) and byte_size(data) <= 1_048_576 do
    opts = Keyword.validate!(opts, separator: nil, skip_headers: true)

    separator =
      case opts[:separator] do
        nil -> :none
        <<byte>> -> {:some, byte}
        _ -> raise ArgumentError, "separator must be a single byte"
      end

    unless is_boolean(opts[:skip_headers]),
      do: raise(ArgumentError, "skip_headers must be boolean")

    case parse_csv(data, separator) do
      {:ok, {rows, _count}} -> {:ok, if(opts[:skip_headers], do: Enum.drop(rows, 1), else: rows)}
      {:error, _} = error -> error
    end
  end

  def parse_string(_, _), do: raise(ArgumentError, "expected a binary of at most 1 MiB")
end
