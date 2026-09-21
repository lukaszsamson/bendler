defmodule Bendler do
  @moduledoc """
  Calls Bend code from Elixir, as a port (the default) or as an experimental
  NIF.

      defmodule Fib do
        use Bendler, otp_app: :my_app, source: "bend/fib.bend"
      end

      # under a supervisor:
      children = [Fib]

      Fib.fib(30, 0, 1)   #=> 832040

  Every exportable def of the Bend file (see `Bendler.Sig`) becomes a
  function of the module, with the same name and arity. Values cross by the
  `Bendler.Codec`: `U32`, `Nat` and `Char` are integers, `F32` a float (or
  `:nan`, `:infinity`, `:neg_infinity`), `String` a binary, `Bool` a
  boolean, `Unit` the atom `:unit`, `List<T>` a list, `A & B` a tuple,
  `Maybe<T>` and `Result<E, T>` tagged tuples, `Map<V>` a map with binary
  keys, and a user `type` of the file a tagged tuple per constructor
  (`{:circle, r}`, or the atom `:dot` for a constructor without fields).
  The module also gets a `@type` per datatype, named after it
  (`Shape` is `shape/0`), so do not declare one of that name yourself.

  ## Options

    * `:otp_app` - the application whose `priv/bendler/` holds the artifact
    * `:source` - the Bend file, relative to the project root
    * `:backend` - `:port` (default) runs an executable under the module's
      `start_link/1`; `:nif` loads a shared library into the VM (experimental:
      VM-lifetime pinning, no runtime unload, fatal errors freeze the module)
    * `:threads` - CPU threads for the Bend runtime, 1..128 (default: the
      schedulers online)
    * `:gpu` - port only: where `!` calls run. `:off` (default) keeps them
      on the CPU pool; `:on` requires a GPU (the port exits at start
      without one); a size like `"4GB"` caps the GPU's heap. A program
      with `!` calls is built with its GPU lane (Metal on macOS, CUDA on
      Linux when installed) and ships its device program as `<name>.gpu`
      beside the executable. A NIF always runs `!` on the CPU pool.
    * `:exports` - the defs to export (default: every exportable def)
    * `:timeout` - milliseconds a call may wait in total (default
      `:infinity`). Port: the owner closes the port and stops, a supervisor
      restarts it. NIF: the caller gives up, the runtime finishes the request
      and its reply is discarded (it cannot be cancelled).
    * `:max_queue` - port: callers allowed to wait behind the one in flight
      (default 8); beyond it a call raises `Bendler.Error` with reason `:busy`
    * `:max_waiting` - NIF: callers admitted at once, waiting or in flight
      (default 4); beyond it a call raises `Bendler.Error` with reason
      `:busy` on the normal scheduler. Only frame validation/copying uses a
      dirty CPU scheduler; waiting for Bend is an ordinary process receive.
      Abandoned running work retains its slot until computation finishes.

  A generated function returns the value, or raises `Bendler.Error` with a
  `reason` of `:busy`, `:timeout`, `:exited` (the port died), `:dead` (the
  NIF runtime hit a fatal error and is frozen) or `:refused` (the program
  rejected the frame). Arguments are checked before encoding and raise
  `ArgumentError`.

  The build runs when the module compiles if the project does not list the
  `:bendler` Mix compiler; with `compilers: Mix.compilers() ++ [:bendler]`
  the module only records a build request and `mix compile.bendler` builds
  it afterwards (`--force` rebuilds, `mix bendler.clean` removes artifacts).
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @bendler_opts opts
      @before_compile Bendler
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :bendler_opts)
    cfg = Bendler.config!(env.module, opts)
    name = env.module |> Macro.underscore() |> String.replace("/", "_")

    request = %{
      module: env.module,
      app: Mix.Project.config()[:app],
      source: cfg.source,
      backend: cfg.backend,
      name: name,
      exports: cfg.exports
    }

    {sigs, types} =
      if Bendler.Build.mix_compiler?() do
        Bendler.Build.request!(request)
      else
        {sigs, types, _artifact} = Bendler.Build.build!(request)
        {sigs, types}
      end

    codec_types = Bendler.Sig.codec_types(types)

    funs =
      sigs
      |> Enum.with_index()
      |> Enum.flat_map(fn {sig, i} -> Bendler.define(sig, i, codec_types, cfg.backend) end)

    typedefs = Enum.map(types, &Bendler.Sig.data_typespec/1)

    quote do
      @external_resource unquote(cfg.source)
      unquote_splicing(typedefs)
      unquote(Bendler.loader(cfg, name))
      unquote_splicing(funs)
    end
  end

  @doc false
  def config!(module, opts) do
    backend = Keyword.get(opts, :backend, :port)
    threads = Keyword.get(opts, :threads, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, :infinity)
    max_queue = Keyword.get(opts, :max_queue, 8)
    max_waiting = Keyword.get(opts, :max_waiting, 4)
    gpu = Keyword.get(opts, :gpu, :off)

    check = fn ok, msg ->
      ok || raise(ArgumentError, "use Bendler in #{inspect(module)}: #{msg}")
    end

    check.(backend in [:port, :nif], "backend must be :port or :nif")
    check.(is_integer(threads) and threads in 1..128, "threads must be 1..128")

    check.(
      timeout == :infinity or (is_integer(timeout) and timeout > 0),
      "timeout must be :infinity or positive milliseconds"
    )

    check.(is_integer(max_queue) and max_queue >= 0, "max_queue must be a non-negative integer")
    check.(is_integer(max_waiting) and max_waiting >= 1, "max_waiting must be at least 1")

    check.(gpu_option?(gpu), "gpu must be :off, :on or a size like \"4GB\"")
    check.(backend == :port or gpu == :off, "gpu applies to the :port backend only")

    %{
      otp_app: Keyword.fetch!(opts, :otp_app),
      source: Path.expand(Keyword.fetch!(opts, :source), File.cwd!()),
      backend: backend,
      threads: threads,
      timeout: timeout,
      max_queue: max_queue,
      max_waiting: max_waiting,
      gpu: gpu,
      exports: Keyword.get(opts, :exports)
    }
  end

  defp gpu_option?(gpu),
    do: gpu in [:off, :on] or (is_binary(gpu) and Regex.match?(~r/^\d+[KMG]B$/, gpu))

  @doc false
  def loader(%{backend: :nif} = cfg, name) do
    # load_nif receives the library stem and adds the platform extension.
    artifact = Bendler.Build.artifact_relative_path(name, :nif) |> String.trim_trailing(".so")

    quote do
      @on_load :__bendler_load__
      @doc false
      def __bendler_load__ do
        path = Path.join(:code.priv_dir(unquote(cfg.otp_app)), unquote(artifact))

        with :ok <-
               :erlang.load_nif(
                 String.to_charlist(path),
                 {unquote(cfg.threads), unquote(cfg.max_waiting),
                  :erlang.system_info(:dirty_cpu_schedulers_online)}
               ) do
          __bendler_init__()
        end
      end

      @doc false
      def __bendler_init__, do: :erlang.nif_error(:bendler_not_loaded)

      @doc false
      def __bendler_submit(_frame, _deadline, _ref), do: :erlang.nif_error(:bendler_not_loaded)

      @doc false
      def __bendler_cancel(_handle), do: :erlang.nif_error(:bendler_not_loaded)

      @doc false
      def __bendler_call(frame, timeout_ms),
        do: Bendler.Nif.call(__MODULE__, frame, Bendler.Nif.deadline(timeout_ms))

      defp __bendler_deadline__, do: Bendler.Nif.deadline(unquote(cfg.timeout))
    end
  end

  def loader(%{backend: :port} = cfg, name) do
    artifact = Bendler.Build.artifact_relative_path(name, :port)

    quote do
      @doc "Starts the Bend port under the caller; also usable as a child spec. Options override the module's."
      def start_link(opts \\ []) do
        exe = Path.join(:code.priv_dir(unquote(cfg.otp_app)), unquote(artifact))

        Bendler.Port.start_link(
          Keyword.merge(
            [
              name: __MODULE__,
              exe: exe,
              launcher: Path.join(Path.dirname(exe), "bendler_launcher"),
              threads: unquote(cfg.threads),
              timeout: unquote(cfg.timeout),
              max_queue: unquote(cfg.max_queue),
              gpu: unquote(cfg.gpu)
            ],
            opts
          )
        )
      end

      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      end

      defp __bendler_deadline__, do: nil
    end
  end

  @doc false
  def unwrap({:bendler_raised, %ErlangError{original: {:bendler_dead, why}}, _}) do
    raise Bendler.Error, message: "the Bend runtime is dead: #{why}", reason: :dead
  end

  def unwrap({:bendler_raised, e, stacktrace}), do: reraise(e, stacktrace)
  def unwrap(other), do: other

  @doc false
  @spec result(binary | {:error, term}, atom) :: term
  def result({:error, {:invalid, why}}, fun) do
    raise Bendler.Error, message: "#{fun}: the request was refused: #{why}", reason: :refused
  end

  def result({:error, reason}, fun) when reason in [:busy, :timeout, :exited, :nomem, :dead] do
    raise Bendler.Error, message: "#{fun}: #{reason}", reason: reason
  end

  def result(bin, fun) when is_binary(bin), do: Bendler.Codec.reply(bin, fun)

  # Keep the telemetry closure in this stable module. A failed load of an
  # identical BEAM can invalidate local fun entries in the target module.
  @doc false
  @spec invoke(module(), atom(), :port | :nif, Bendler.Nif.deadline() | nil, tuple()) :: term()
  def invoke(module, fun, backend, deadline, {index, pairs, codec, return_type}) do
    Bendler.Telemetry.span(module, fun, backend, fn ->
      frame = Bendler.Codec.request(index, pairs, codec)
      reply = send_frame(backend, module, frame, deadline)
      Bendler.Codec.check(result(reply, fun), return_type, fun, codec)
    end)
  end

  @doc false
  @spec stream(module(), atom(), tuple()) :: Enumerable.t()
  def stream(module, fun, {index, pairs, codec, return_type, event_type}) do
    Stream.resource(
      fn -> open_stream(module, fun, index, pairs, codec) end,
      &pull(&1, fun, return_type, event_type, codec),
      &release_stream/1
    )
  end

  defp open_stream(module, fun, index, pairs, codec) do
    span = Bendler.Telemetry.open(module, fun, :port)
    frame = Bendler.Codec.request(index, pairs, codec)

    case Bendler.Port.stream(module, frame) do
      {:ok, ref} ->
        %{
          module: module,
          ref: ref,
          span: span,
          monitor: Process.monitor(module),
          owed: false,
          done: false
        }

      {:error, reason} ->
        Bendler.Telemetry.close_exception(span, :error, reason)
        raise Bendler.Error, message: "#{fun}: #{reason}", reason: reason
    end
  end

  # Demand drives the acknowledgements: the one for the event just yielded
  # goes out when the consumer asks for the next, so a paused consumer
  # holds at most one event and the worker waits inside `Bendler.emit`.
  #
  # `pull` may leave by raising, and `Stream.resource`'s release then sees
  # the state as it was before that call. A per-stream process key records
  # that the request is already over, so the release does not wait for a
  # reply that can no longer come.
  defp pull(%{done: true} = st, _fun, _ret, _event, _codec), do: {:halt, st}

  defp pull(st, fun, ret, event, codec) do
    if st.owed, do: Bendler.Port.ack(st.module, st.ref, true)
    st = %{st | owed: false}
    ref = st.ref
    mon = st.monitor

    receive do
      {:bendler_event, ^ref, body} ->
        {[{:event, Bendler.Codec.event(body, event, fun, codec)}], %{st | owed: true}}

      {:bendler_done, ^ref, reply, measurements} ->
        Process.put(over(ref), true)
        done(st, reply, measurements, fun, ret, codec)

      {:DOWN, ^mon, :process, _, _} ->
        Process.put(over(ref), true)
        Bendler.Telemetry.close_exception(st.span, :error, :exited)
        raise Bendler.Error, message: "#{fun}: exited", reason: :exited
    end
  end

  defp done(st, reply, measurements, fun, ret, codec) do
    value = Bendler.Codec.check(result(reply, fun), ret, fun, codec)
    Bendler.Telemetry.close(st.span, :stop, measurements)
    {[{:done, value}], %{st | span: nil, done: true}}
  rescue
    e ->
      Bendler.Telemetry.close_exception(st.span, :error, e)
      reraise e, __STACKTRACE__
  end

  defp over(ref), do: {__MODULE__, :stream, ref}

  # Halting early (Enum.take, a raise in the consumer) refuses the next
  # event, then waits for the def to answer, so the port serves the next
  # call as soon as this one returns.
  defp release_stream(st) do
    _ = Process.demonitor(st.monitor, [:flush])

    unless Process.delete(over(st.ref)) do
      Bendler.Port.ack(st.module, st.ref, false)
      mon = Process.monitor(st.module)
      drain_stream(st, mon)
      _ = Process.demonitor(mon, [:flush])
    end

    :ok
  end

  defp drain_stream(st, mon) do
    ref = st.ref

    receive do
      {:bendler_event, ^ref, _} ->
        Bendler.Port.ack(st.module, st.ref, false)
        drain_stream(st, mon)

      {:bendler_done, ^ref, _, measurements} ->
        Bendler.Telemetry.close(st.span, :stop, measurements)

      {:DOWN, ^mon, :process, _, _} ->
        Bendler.Telemetry.close_exception(st.span, :error, :exited)
    end
  end

  defp send_frame(:port, module, frame, _deadline), do: Bendler.Port.call(module, frame)

  defp send_frame(:nif, module, frame, deadline) do
    try do
      Bendler.Nif.call(module, frame, deadline)
    rescue
      e in ErlangError -> {:bendler_raised, e, __STACKTRACE__}
    end
    |> unwrap()
  end

  @doc false
  def define(
        %Bendler.Sig{name: name, params: params, ret: {ret_t, ret_text}} = sig,
        index,
        codec,
        backend
      ) do
    fname = name |> String.replace(".", "_") |> String.to_atom()
    vars = Enum.map(params, &Macro.var(String.to_atom(&1.name), __MODULE__))
    pairs = Enum.zip(vars, Enum.map(params, & &1.type))
    types = Enum.map(params, &Bendler.Sig.typespec(&1.type))
    ret_spec = Bendler.Sig.typespec(ret_t)

    sig_text =
      "def #{name}(#{Enum.map_join(params, ", ", &"#{if &1.reusable, do: "+", else: ""}#{&1.name}: #{&1.text}")}) -> #{ret_text}"

    args = Enum.map(pairs, fn {v, t} -> quote(do: {unquote(v), unquote(Macro.escape(t))}) end)

    call =
      quote do
        @doc "Bend: `#{unquote(sig_text)}`#{unquote(doc_tail(sig))} (line #{unquote(sig.line)})."
        @spec unquote(fname)(unquote_splicing(types)) :: unquote(ret_spec)
        def unquote(fname)(unquote_splicing(vars)) do
          deadline = __bendler_deadline__()

          Bendler.invoke(
            __MODULE__,
            unquote(fname),
            unquote(backend),
            deadline,
            {unquote(index), unquote(args), unquote(Macro.escape(codec)),
             unquote(Macro.escape(ret_t))}
          )
        end
      end

    [call | stream_fun(sig, fname, index, vars, args, codec, ret_t, ret_spec, types, sig_text)]
  end

  defp doc_tail(%Bendler.Sig{emitter: nil}), do: ""

  defp doc_tail(%Bendler.Sig{emitter: e}),
    do:
      ", whose events are discarded: the first `#{e.name}` is answered `False`, " <>
        "so the def stops early. Use the `_stream` function to receive them"

  defp stream_fun(%Bendler.Sig{emitter: nil}, _, _, _, _, _, _, _, _, _), do: []

  defp stream_fun(
         %Bendler.Sig{emitter: e},
         fname,
         index,
         vars,
         args,
         codec,
         ret_t,
         ret_spec,
         types,
         sig_text
       ) do
    sname = :"#{fname}_stream"
    event_spec = Bendler.Sig.typespec(e.type)

    [
      quote do
        @doc """
        The lazy event stream of `#{unquote(sig_text)}`.

        Yields `{:event, value}` per event the def emits through
        `#{unquote(e.name)}`, decoded and checked against
        `#{unquote(e.text)}`, and ends with `{:done, result}`. Demand
        drives the acknowledgements: the one for an event goes out when
        the next is asked for, so a paused consumer holds one event and
        the worker waits inside its emit. Halting early (`Enum.take/2`,
        a raise) makes the next emit answer `False`, and the stream
        releases the request once the def has returned.
        """
        @spec unquote(sname)(unquote_splicing(types)) ::
                Enumerable.t({:event, unquote(event_spec)} | {:done, unquote(ret_spec)})
        def unquote(sname)(unquote_splicing(vars)) do
          Bendler.stream(
            __MODULE__,
            unquote(sname),
            {unquote(index), unquote(args), unquote(Macro.escape(codec)),
             unquote(Macro.escape(ret_t)), unquote(Macro.escape(e.type))}
          )
        end
      end
    ]
  end
end
