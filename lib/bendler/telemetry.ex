defmodule Bendler.Telemetry do
  @moduledoc """
  Generated calls emit `[:bendler, :call, :start | :stop | :exception]`.
  Metadata contains `module`, `function`, `backend` and a unique
  `telemetry_span_context`. Arguments and returned values are never emitted.
  Durations use native monotonic time units. Port completions add
  `queue_depth` (waiting requests at admission), `wait_time` and `run_time`
  (dispatch through reply, including transport). NIF timings are end-to-end
  only: its internal wait/run split is not measured.
  Exceptions include `kind` and a sanitized `reason`, not arguments or
  exception messages. A process killed by an exit signal may emit start only.
  """
  @key {__MODULE__, :measurements}

  @doc false
  @spec span(module(), atom(), :port | :nif, (-> value)) :: value when value: term()
  def span(module, function, backend, fun) do
    previous = Process.put(@key, %{})

    metadata = %{
      module: module,
      function: function,
      backend: backend,
      telemetry_span_context: make_ref()
    }

    started = System.monotonic_time()

    :telemetry.execute(
      [:bendler, :call, :start],
      %{system_time: System.system_time(), monotonic_time: started},
      metadata
    )

    try do
      result = fun.()
      emit(:stop, started, metadata)
      result
    catch
      kind, reason ->
        emit(:exception, started, Map.merge(metadata, %{kind: kind, reason: reason_tag(reason)}))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @typedoc "A span opened by `open/3` and closed by `close/3`."
  @opaque span :: {map(), integer()}

  @doc """
  Opens a span whose stop is emitted later, for a lazily consumed stream:
  its start and stop happen in different calls, so `span/4` cannot wrap it.
  """
  @spec open(module(), atom(), :port | :nif) :: span()
  def open(module, function, backend) do
    metadata = %{
      module: module,
      function: function,
      backend: backend,
      telemetry_span_context: make_ref()
    }

    started = System.monotonic_time()

    :telemetry.execute(
      [:bendler, :call, :start],
      %{system_time: System.system_time(), monotonic_time: started},
      metadata
    )

    {metadata, started}
  end

  @doc "Closes a span opened by `open/3`: `:stop`, or `:exception` with a reason."
  @spec close(span(), :stop | :exception, map()) :: :ok
  def close({metadata, started}, event, measurements) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:bendler, :call, event],
      Map.merge(measurements, %{duration: now - started, monotonic_time: now}),
      metadata
    )
  end

  @doc "Closes a span opened by `open/3` as an exception of `kind` and `reason`."
  @spec close_exception(span(), atom(), term()) :: :ok
  def close_exception({metadata, started}, kind, reason) do
    close(
      {Map.merge(metadata, %{kind: kind, reason: reason_tag(reason)}), started},
      :exception,
      %{}
    )
  end

  @doc false
  @spec record(map()) :: :ok
  def record(measurements) do
    if Process.get(@key) != nil, do: Process.put(@key, measurements)
    :ok
  end

  defp emit(event, started, metadata) do
    now = System.monotonic_time()

    measurements =
      Map.merge(Process.get(@key, %{}), %{duration: now - started, monotonic_time: now})

    :telemetry.execute([:bendler, :call, event], measurements, metadata)
  end

  defp reason_tag(%Bendler.Error{reason: reason}), do: reason
  defp reason_tag(%{__exception__: true, __struct__: module}), do: module
  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(_), do: :other
end
