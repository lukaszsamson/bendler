defmodule Bendler.Nif do
  @moduledoc false
  @type deadline :: integer() | :infinity

  @spec deadline(:infinity | integer()) :: deadline()
  def deadline(timeout) when timeout in [:infinity, -1], do: :infinity

  def deadline(timeout) when is_integer(timeout) and timeout >= 0,
    do: System.monotonic_time(:millisecond) + timeout

  @spec call(module(), binary(), deadline()) :: binary() | {:error, term()}
  def call(module, frame, deadline) do
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
