defmodule Bendler.Port do
  @moduledoc """
  Runs a Bend port executable and serialises calls to it. Frames are
  4-byte-length-prefixed request and reply binaries (see `Bendler.Codec`).

  Admission is bounded: one request is in flight and at most `max_queue`
  wait behind it; further callers get `{:error, :busy}` at once. The
  deadline is total and owner-held: it starts when the request is accepted
  (queue time included). A request that outlives `timeout` closes the port
  and stops the owner with `{:shutdown, :timeout}`; the waiting callers get
  `{:error, :timeout}` or `{:error, :exited}`. A supervisor restarts the
  owner; nothing is retried. A queued caller that dies is dropped from the
  queue. The port exits 0 on EOF, 65 on a framing error and 74 on a
  transport error; each stops the owner with `{:shutdown, {:exit_status,
  code}}`. A well-framed but invalid request is answered with an error
  frame and the worker goes on.

  A native launcher owns the worker process group. Closing the port (also
  when this owner is killed) makes the launcher send TERM, then KILL after
  200 ms, and reap the worker. This does not depend on worker cooperation.
  """
  use GenServer
  require Logger

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends a request frame and waits for the reply frame, or an error tuple."
  @spec call(GenServer.server(), binary) :: binary | {:error, :busy | :timeout | :exited}
  def call(server, frame) do
    case GenServer.call(server, {:call, frame}, :infinity) do
      {:bendler_reply, reply, measurements} ->
        Bendler.Telemetry.record(measurements)
        reply

      reply ->
        reply
    end
  catch
    :exit, {_reason, {GenServer, :call, _}} -> {:error, :exited}
  end

  @impl true
  def init(opts) do
    exe = Keyword.fetch!(opts, :exe)
    launcher = Keyword.get(opts, :launcher, Path.join(Path.dirname(exe), "bendler_launcher"))
    threads = Keyword.get(opts, :threads, System.schedulers_online())
    Process.flag(:trap_exit, true)

    port =
      Port.open({:spawn_executable, launcher}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: [
          exe,
          "--threads",
          Integer.to_string(threads),
          "--gpu",
          gpu_arg(Keyword.get(opts, :gpu, :off))
        ]
      ])

    {:ok,
     %{
       port: port,
       inflight: nil,
       queue: :queue.new(),
       queued: 0,
       max_queue: Keyword.get(opts, :max_queue, 8),
       timeout: Keyword.get(opts, :timeout, :infinity)
     }}
  end

  # A request: its frame, its caller, the caller's monitor and its deadline timer.
  @impl true
  def handle_call({:call, _}, _from, %{queued: n, max_queue: max, inflight: inflight} = s)
      when inflight != nil and n >= max do
    {:reply, {:bendler_reply, {:error, :busy}, %{queue_depth: n, wait_time: 0, run_time: 0}}, s}
  end

  def handle_call({:call, frame}, {pid, _} = from, s) do
    req = %{
      frame: frame,
      from: from,
      monitor: Process.monitor(pid),
      admitted: System.monotonic_time(),
      dispatched: nil,
      queue_depth: s.queued,
      timer: start_timer(s.timeout, from)
    }

    if s.inflight == nil do
      dispatch(req, s)
    else
      {:noreply, %{s | queue: :queue.in(req, s.queue), queued: s.queued + 1}}
    end
  end

  defp gpu_arg(:off), do: "off"
  defp gpu_arg(:on), do: "on"
  defp gpu_arg(cap) when is_binary(cap), do: cap

  defp start_timer(:infinity, _from), do: nil
  defp start_timer(ms, from), do: Process.send_after(self(), {:deadline, from}, ms)

  # Sends the request or fails it, then keeps draining the queue until a
  # request is in flight, the queue is empty, or the port is gone. Every
  # outcome is a handle_info/handle_call-neutral {:noreply, state} or
  # {:stop, reason, state}, and never leaves queued requests unscheduled.
  defp dispatch(req, s) do
    case send_frame(s.port, req.frame) do
      :ok ->
        {:noreply, %{s | inflight: %{req | dispatched: System.monotonic_time()}}}

      :busy ->
        finish(req, {:error, :busy})
        drain(s)

      :closed ->
        finish(req, {:error, :exited})
        {:stop, {:shutdown, :port_closed}, s}
    end
  end

  defp drain(%{inflight: nil} = s) do
    case :queue.out(s.queue) do
      {{:value, next}, q} -> dispatch(next, %{s | queue: q, queued: s.queued - 1})
      {:empty, _} -> {:noreply, s}
    end
  end

  defp send_frame(port, frame) do
    if Port.command(port, frame, [:nosuspend]), do: :ok, else: :busy
  rescue
    ArgumentError -> :closed
  end

  defp finish(req, reply) do
    _ = cancel(req.timer)
    _ = Process.demonitor(req.monitor, [:flush])
    now = System.monotonic_time()
    dispatched = req.dispatched || now

    measurements = %{
      queue_depth: req.queue_depth,
      wait_time: dispatched - req.admitted,
      run_time: now - dispatched
    }

    GenServer.reply(req.from, {:bendler_reply, reply, measurements})
  end

  @impl true
  def handle_info({port, {:data, reply}}, %{port: port, inflight: req} = s) when req != nil do
    finish(req, reply)
    drain(%{s | inflight: nil})
  end

  def handle_info({:deadline, from}, %{inflight: %{from: from} = req} = s) do
    finish(req, {:error, :timeout})
    {:stop, {:shutdown, :timeout}, %{s | inflight: nil}}
  end

  def handle_info({:deadline, from}, s) do
    # a queued request ran out its total deadline: drop it, keep serving
    {dropped, rest} = split(s.queue, &(&1.from == from))

    for req <- dropped, do: finish(req, {:error, :timeout})
    {:noreply, %{s | queue: rest, queued: s.queued - length(dropped)}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    # a queued caller died: forget its request (an in-flight one must complete to keep frames aligned)
    {gone, rest} = split(s.queue, &(&1.monitor == ref))

    Enum.each(gone, &cancel(&1.timer))
    {:noreply, %{s | queue: rest, queued: s.queued - length(gone)}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s) do
    Logger.warning("bendler: port exited with status #{code}")
    {:stop, {:shutdown, {:exit_status, code}}, s}
  end

  def handle_info({:EXIT, _, reason}, s), do: {:stop, reason, s}

  defp cancel(nil), do: :ok
  defp cancel(timer), do: _ = Process.cancel_timer(timer)

  defp split(queue, pred) do
    {yes, no} = queue |> :queue.to_list() |> Enum.split_with(pred)
    {yes, :queue.from_list(no)}
  end

  @impl true
  def terminate(_reason, s) do
    if s.inflight, do: finish(s.inflight, {:error, :exited})
    for req <- :queue.to_list(s.queue), do: finish(req, {:error, :exited})
    if Port.info(s.port) != nil, do: Port.close(s.port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
