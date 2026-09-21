defmodule Bendler.Demos.CsvStream.Error do
  @moduledoc "CSV syntax or record-limit failure, with an absolute zero-based byte offset."
  defexception [:message, :code, :byte_offset]
end

defmodule Bendler.Demos.CsvStream do
  @moduledoc """
  Lazy, byte-preserving CSV parsing through bounded incremental Bend calls.

  Start `Bendler.Demos.CsvStreamPort` under a supervisor before enumerating.
  `backend: :nif` selects the experimental NIF binding (no server to start).
  Input is an Enumerable of arbitrary binary chunks, not necessarily lines.
  Output is an Enumerable of rows. The default drops the first row.

  Each demand pulls at most one bounded chunk into Bend and keeps the returned
  batch locally until consumed. There is no producer process or event mailbox.
  Early halt stops pulling input; parser state is owned by the enumeration,
  never by the shared native runtime. Concurrent streams cannot mix cursors.

  `chunk_bytes` defaults to 16 KiB; `max_record_bytes` to 64 KiB (both at most
  64 KiB). The latter includes quotes, delimiters and record terminators.
  Native calls have the binding's 5-second deadline, not a whole-stream deadline.
  The source Enumerable's own blocking, allocation and cleanup are its contract.
  Rows emitted before a later error cannot be rolled back.
  """

  alias Bendler.Demos.CsvStream.Error
  alias Bendler.Demos.{CsvStreamNif, CsvStreamPort}

  @doc "Parses arbitrary binary chunks lazily; selects :port (default) or experimental :nif via :backend."
  @spec parse_stream(Enumerable.t(), keyword()) :: Enumerable.t()
  def parse_stream(source, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        backend: :port,
        separator: ",",
        skip_headers: true,
        chunk_bytes: 16_384,
        max_record_bytes: 65_536
      )

    sep = separator!(opts[:separator])
    chunk = bound!(opts[:chunk_bytes], :chunk_bytes)
    limit = bound!(opts[:max_record_bytes], :max_record_bytes)
    skip = opts[:skip_headers]
    unless is_boolean(skip), do: raise(ArgumentError, "skip_headers must be boolean")
    module = backend!(opts[:backend])

    source
    |> Stream.flat_map(&chunks(&1, chunk))
    |> Stream.transform(
      fn -> %{cursor: {0, 0, 0, <<>>, [], false}, skip: skip} end,
      fn bytes, state -> feed(module, state, bytes, false, sep, limit) end,
      fn state -> feed(module, state, <<>>, true, sep, limit) end,
      fn _state -> :ok end
    )
  end

  defp chunks(bytes, size) when is_binary(bytes) do
    Stream.unfold(bytes, fn
      <<>> ->
        nil

      rest ->
        n = min(byte_size(rest), size)
        <<part::binary-size(^n), tail::binary>> = rest
        {part, tail}
    end)
  end

  defp chunks(_, _), do: raise(ArgumentError, "CSV source must yield binaries")

  defp feed(module, state, bytes, eof, sep, limit) do
    case module.feed_csv(state.cursor, bytes, eof, sep, limit) do
      {:ok, {cursor, rows}} ->
        {rows, skip} = drop_header(rows, state.skip)
        {rows, %{state | cursor: cursor, skip: skip}}

      {:error, {code, offset, message}} ->
        raise Error, code: code, byte_offset: offset, message: "#{message} at byte #{offset}"
    end
  end

  defp drop_header([], skip), do: {[], skip}
  defp drop_header([_ | rows], true), do: {rows, false}
  defp drop_header(rows, false), do: {rows, false}

  defp separator!(<<sep>>) when sep not in [10, 13, 34], do: sep

  defp separator!(_),
    do: raise(ArgumentError, "separator must be one byte other than quote, CR or LF")

  defp bound!(n, _) when is_integer(n) and n in 1..65_536, do: n
  defp bound!(_, option), do: raise(ArgumentError, "#{option} must be 1..65536")

  defp backend!(:port), do: CsvStreamPort
  defp backend!(:nif), do: CsvStreamNif
  defp backend!(_), do: raise(ArgumentError, "backend must be :port or :nif")
end
