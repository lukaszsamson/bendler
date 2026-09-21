defmodule Bendler.Nif do
  @moduledoc false
  @type deadline :: integer() | :infinity

  @spec deadline(:infinity | integer()) :: deadline()
  def deadline(timeout) when timeout in [:infinity, -1], do: :infinity

  def deadline(timeout) when is_integer(timeout) and timeout >= 0,
    do: System.monotonic_time(:millisecond) + timeout

  @spec call(module(), binary(), deadline()) :: binary() | {:error, term()}
  def call(module, frame, deadline) do
    check_reentry!(module)
    ref = make_ref()

    case module.__bendler_submit(frame, deadline, ref) do
      {:ok, handle} ->
        try do
          await(ref, deadline)
        after
          # Native cancellation synchronizes with sending. After it returns
          # any racing reply is already in the mailbox, never still in flight.
          :ok = module.__bendler_cancel(handle)

          receive do
            {:bendler_reply, ^ref, _} -> :ok
          after
            0 -> :ok
          end
        end

      {:error, _} = error ->
        error
    end
  end

  @spec ask(module(), binary(), deadline(), (binary() -> binary())) :: binary() | {:error, term()}
  def ask(module, frame, deadline, callback) do
    check_reentry!(module)
    ref = make_ref()

    case module.__bendler_subscribe(frame, deadline, ref) do
      {:ok, handle} ->
        try do
          ask_loop(module, handle, ref, deadline, callback)
        after
          :ok = module.__bendler_cancel(handle)
          flush_stream(ref)
        end

      error ->
        error
    end
  end

  defp ask_loop(module, handle, ref, deadline, callback) do
    case await_event(ref, deadline) do
      {:reply, reply} ->
        reply

      {:event, seq, body} ->
        with {:ok, answer} <- callback_reply(module, ref, deadline, callback, body),
             :ok <- submit_answer(module, handle, seq, answer, deadline) do
          ask_loop(module, handle, ref, deadline, callback)
        end
    end
  end

  defp submit_answer(module, handle, seq, answer, deadline) do
    case module.__bendler_answer(handle, seq, answer) do
      :ok ->
        :ok

      _ ->
        reason =
          if deadline != :infinity and System.monotonic_time(:millisecond) >= deadline,
            do: :timeout,
            else: :callback

        {:error, reason}
    end
  end

  # The guardian monitors the caller and owns the linked handler. Neither a
  # caller kill nor a handler crash can leave an unbounded callback process.
  defp callback_reply(module, ref, deadline, callback, body) do
    owner = self()
    {guard, mon} = spawn_monitor(fn -> guard_callback(owner, module, ref, callback, body) end)

    try do
      wait_callback(ref, mon, deadline)
    after
      send(guard, :stop)

      receive do
        {:DOWN, ^mon, :process, ^guard, _} -> :ok
      end

      receive do
        {:bendler_callback, ^ref, _} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp wait_callback(ref, mon, deadline) do
    wait =
      if deadline == :infinity,
        do: 5000,
        else: min(5000, max(0, deadline - System.monotonic_time(:millisecond)))

    receive do
      {:bendler_callback, ^ref, answer} ->
        answer

      {:bendler_reply, ^ref, reply} ->
        reply

      {:DOWN, ^mon, :process, _, _} = down ->
        send(self(), down)
        {:error, :callback}
    after
      wait ->
        {:error,
         if(deadline != :infinity and System.monotonic_time(:millisecond) >= deadline,
           do: :timeout,
           else: :callback
         )}
    end
  end

  defp guard_callback(owner, module, ref, callback, body) do
    Process.flag(:trap_exit, true)
    owner_mon = Process.monitor(owner)
    guard = self()

    worker =
      spawn_link(fn ->
        Process.put({__MODULE__, :callback_owner}, module)

        answer =
          try do
            {:ok, callback.(body)}
          catch
            _, _ -> {:error, :callback}
          end

        send(guard, {:answer, answer})
      end)

    receive do
      {:answer, answer} ->
        send(owner, {:bendler_callback, ref, answer})

        receive do
          :stop -> :ok
          {:DOWN, ^owner_mon, :process, ^owner, _} -> :ok
        after
          5000 -> :ok
        end

      {:EXIT, ^worker, _} ->
        send(owner, {:bendler_callback, ref, {:error, :callback}})

        receive do
          :stop -> :ok
        after
          5000 -> :ok
        end

      :stop ->
        :ok

      {:DOWN, ^owner_mon, :process, ^owner, _} ->
        :ok
    after
      5000 -> :ok
    end

    worker_mon = Process.monitor(worker)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^worker_mon, :process, ^worker, _} -> :ok
    end
  end

  defp check_reentry!(module) do
    if Process.get({__MODULE__, :callback_owner}) == module do
      raise Bendler.Error, reason: :reentrant, message: "callback cannot call its own NIF module"
    end
  end

  @spec stream(module(), atom(), tuple(), :infinity | non_neg_integer()) :: Enumerable.t()
  def stream(module, fun, {index, pairs, codec, ret, event}, timeout) do
    Stream.resource(
      fn -> open_stream(module, fun, index, pairs, codec, deadline(timeout)) end,
      &pull(&1, fun, codec, ret, event),
      &release_stream/1
    )
  end

  defp open_stream(module, fun, index, pairs, codec, deadline) do
    check_reentry!(module)
    frame = Bendler.Codec.request(index, pairs, codec)
    ref = make_ref()
    span = Bendler.Telemetry.open(module, fun, :nif)

    case module.__bendler_subscribe(frame, deadline, ref) do
      {:ok, handle} ->
        %{
          module: module,
          ref: ref,
          handle: handle,
          deadline: deadline,
          owed: nil,
          done: false,
          span: span
        }

      {:error, reason} = error ->
        Bendler.Telemetry.close_exception(span, :error, error)
        reason = if match?({:invalid, _}, reason), do: :refused, else: reason
        raise Bendler.Error, message: "#{fun}: #{reason}", reason: reason
    end
  end

  defp pull(%{done: true} = st, _, _, _, _), do: {:halt, st}

  defp pull(st, fun, codec, ret, event) do
    if st.owed, do: st.module.__bendler_ack(st.handle, st.owed, true)

    case await_event(st.ref, st.deadline) do
      {:event, seq, body} ->
        {[{:event, Bendler.Codec.event(body, event, fun, codec)}], %{st | owed: seq}}

      {:reply, reply} ->
        value = Bendler.Codec.check(Bendler.result(reply, fun), ret, fun, codec)
        {[{:done, value}], %{st | owed: nil, done: true}}
    end
  rescue
    e ->
      Process.put({__MODULE__, st.ref}, e)
      reraise e, __STACKTRACE__
  end

  defp await_event(ref, deadline) do
    remaining =
      if deadline == :infinity,
        do: :infinity,
        else: max(0, deadline - System.monotonic_time(:millisecond))

    wait = if remaining == :infinity, do: :infinity, else: min(remaining, 0xFFFFFFFF)

    if remaining == 0 do
      {:reply, {:error, :timeout}}
    else
      receive_event(ref, deadline, wait)
    end
  end

  defp receive_event(ref, deadline, wait) do
    receive do
      {:bendler_event, ^ref, seq, body} -> {:event, seq, body}
      {:bendler_reply, ^ref, reply} -> {:reply, reply}
    after
      wait ->
        await_event(ref, deadline)
    end
  end

  defp release_stream(st) do
    # Cancellation and native sending share the lock. After cancel returns,
    # drain racing messages; none for this request can be sent later.
    :ok = st.module.__bendler_cancel(st.handle)
    flush_stream(st.ref)

    case Process.delete({__MODULE__, st.ref}) do
      nil -> Bendler.Telemetry.close(st.span, :stop, %{})
      error -> Bendler.Telemetry.close_exception(st.span, :error, error)
    end
  end

  defp flush_stream(ref) do
    receive do
      {:bendler_event, ^ref, _, _} -> flush_stream(ref)
      {:bendler_reply, ^ref, _} -> flush_stream(ref)
    after
      0 -> :ok
    end
  end

  defp await(ref, :infinity) do
    receive do
      {:bendler_reply, ^ref, reply} -> reply
    end
  end

  defp await(ref, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:bendler_reply, ^ref, reply} -> reply
    after
      min(remaining, 0xFFFFFFFF) ->
        if remaining > 0xFFFFFFFF, do: await(ref, deadline), else: {:error, :timeout}
    end
  end
end
