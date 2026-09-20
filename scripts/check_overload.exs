# MIX_ENV=test mix run scripts/check_overload.exs
# Observational RSS check, not an OS memory limit or proof against arbitrary code.
defmodule Bendler.OverloadCheck do
  alias Bendler.Examples.FibPort

  def processes do
    {output, 0} = System.cmd("ps", ["-axo", "pid=,ppid=,rss="])

    for line <- String.split(output, "\n", trim: true),
        [pid, parent, rss] = String.split(line),
        into: %{},
        do: {String.to_integer(pid), {String.to_integer(parent), String.to_integer(rss)}}
  end

  def sample(worker) do
    entries = processes()
    {_, worker_rss} = Map.fetch!(entries, worker)
    {_, beam_rss} = Map.fetch!(entries, String.to_integer(System.pid()))
    %{worker_kib: worker_rss, beam_kib: beam_rss}
  end

  def watch(worker, peak) do
    receive do
      {:finish, caller} -> send(caller, {:peak, peak})
    after
      25 ->
        next = sample(worker)
        watch(worker, Map.merge(peak, next, fn _, a, b -> max(a, b) end))
    end
  end

  def run do
    {:ok, owner} = FibPort.start_link(threads: 1, max_queue: 4, timeout: 10_000)

    try do
      data = :binary.copy(<<7>>, 65_536)
      expected = 7 * byte_size(data)
      for _ <- 1..10, do: ^expected = FibPort.byte_sum(data)
      %{port: port} = :sys.get_state(owner)
      {:os_pid, launcher} = Port.info(port, :os_pid)
      {worker, _} = Enum.find(processes(), fn {_, {parent, _}} -> parent == launcher end)
      baseline = sample(worker)
      sampler = spawn_link(fn -> watch(worker, baseline) end)

      counts =
        Enum.reduce(1..40, %{ok: 0, busy: 0}, fn _, counts ->
          results =
            Task.async_stream(
              1..64,
              fn _ ->
                try do
                  ^expected = FibPort.byte_sum(data)
                  :ok
                rescue
                  e in Bendler.Error ->
                    if e.reason == :busy, do: :busy, else: reraise(e, __STACKTRACE__)
                end
              end,
              max_concurrency: 64,
              timeout: 15_000
            )

          counts =
            Enum.reduce(results, counts, fn {:ok, result}, acc ->
              Map.update!(acc, result, &(&1 + 1))
            end)

          %{queued: queued} = :sys.get_state(owner)
          if queued > 4, do: raise("queue exceeded configured bound")
          counts
        end)

      send(sampler, {:finish, self()})

      peak =
        receive do
          {:peak, peak} -> peak
        after
          5000 -> raise "RSS sampler timed out"
        end

      final = sample(worker)
      peak = Map.merge(peak, final, fn _, a, b -> max(a, b) end)

      if counts.busy == 0 or counts.ok == 0,
        do: raise("check did not exercise both admission outcomes")

      if final.worker_kib - baseline.worker_kib > 131_072,
        do: raise("worker retained >128 MiB above warm baseline")

      IO.inspect(%{requests: 2560, counts: counts, baseline: baseline, peak: peak, final: final},
        label: "overload RSS (KiB)"
      )
    after
      GenServer.stop(owner)
    end
  end
end

Bendler.OverloadCheck.run()
