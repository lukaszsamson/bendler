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
  keys.

  ## Options

    * `:otp_app` - the application whose `priv/bendler/` holds the artifact
    * `:source` - the Bend file, relative to the project root
    * `:backend` - `:port` (default) runs an executable under the module's
      `start_link/1`; `:nif` loads a shared library into the VM (experimental:
      no unload, a fatal runtime error freezes the module, callers wait on
      dirty schedulers)
    * `:threads` - CPU threads for the Bend runtime, 1..128 (default: the
      schedulers online)
    * `:exports` - the defs to export (default: every exportable def)
    * `:timeout` - milliseconds a call may wait in total (default
      `:infinity`). Port: the owner closes the port and stops, a supervisor
      restarts it. NIF: the caller gives up, the runtime finishes the request
      and its reply is discarded (it cannot be cancelled).
    * `:max_queue` - port: callers allowed to wait behind the one in flight
      (default 8); beyond it a call raises `Bendler.Error` with reason `:busy`
    * `:max_waiting` - NIF: callers admitted at once, waiting or in flight
      (default 4), each holding a dirty CPU scheduler thread; beyond it a
      call raises `Bendler.Error` with reason `:busy`. Admission happens on
      the dirty scheduler, so with every dirty scheduler busy the call waits
      for one first.

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

    sigs =
      if Bendler.Build.mix_compiler?() do
        Bendler.Build.request!(request)
      else
        {sigs, _artifact} = Bendler.Build.build!(request)
        sigs
      end

    funs =
      sigs
      |> Enum.with_index()
      |> Enum.map(fn {sig, i} -> Bendler.define(sig, i) end)

    quote do
      @external_resource unquote(cfg.source)
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

    %{
      otp_app: Keyword.fetch!(opts, :otp_app),
      source: Path.expand(Keyword.fetch!(opts, :source), File.cwd!()),
      backend: backend,
      threads: threads,
      timeout: timeout,
      max_queue: max_queue,
      max_waiting: max_waiting,
      exports: Keyword.get(opts, :exports)
    }
  end

  @doc false
  def loader(%{backend: :nif} = cfg, name) do
    ms = if cfg.timeout == :infinity, do: -1, else: cfg.timeout

    quote do
      @on_load :__bendler_load__
      @doc false
      def __bendler_load__ do
        path = Path.join([:code.priv_dir(unquote(cfg.otp_app)), "bendler", unquote(name)])

        :erlang.load_nif(
          String.to_charlist(path),
          {unquote(cfg.threads), unquote(cfg.max_waiting)}
        )
      end

      @doc false
      def __bendler_call(_frame, _timeout_ms), do: :erlang.nif_error(:bendler_not_loaded)

      defp __bendler_send__(frame) do
        try do
          __bendler_call(frame, unquote(ms))
        rescue
          e in ErlangError -> {:bendler_raised, e, __STACKTRACE__}
        end
        |> Bendler.unwrap()
      end
    end
  end

  def loader(%{backend: :port} = cfg, name) do
    quote do
      @doc "Starts the Bend port under the caller; also usable as a child spec. Options override the module's."
      def start_link(opts \\ []) do
        exe = Path.join([:code.priv_dir(unquote(cfg.otp_app)), "bendler", unquote(name)])

        Bendler.Port.start_link(
          Keyword.merge(
            [
              name: __MODULE__,
              exe: exe,
              threads: unquote(cfg.threads),
              timeout: unquote(cfg.timeout),
              max_queue: unquote(cfg.max_queue)
            ],
            opts
          )
        )
      end

      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      end

      defp __bendler_send__(frame), do: Bendler.Port.call(__MODULE__, frame)
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

  def result({:error, reason}, fun) when reason in [:busy, :timeout, :exited, :nomem] do
    raise Bendler.Error, message: "#{fun}: #{reason}", reason: reason
  end

  def result(bin, fun) when is_binary(bin), do: Bendler.Codec.reply(bin, fun)

  @doc false
  def define(%Bendler.Sig{name: name, params: params, ret: {ret_t, ret_text}} = sig, index) do
    fname = name |> String.replace(".", "_") |> String.to_atom()
    vars = Enum.map(params, &Macro.var(String.to_atom(&1.name), __MODULE__))
    pairs = Enum.zip(vars, Enum.map(params, & &1.type))
    types = Enum.map(params, &Bendler.Sig.typespec(&1.type))
    ret_spec = Bendler.Sig.typespec(ret_t)

    sig_text =
      "def #{name}(#{Enum.map_join(params, ", ", &"#{if &1.reusable, do: "+", else: ""}#{&1.name}: #{&1.text}")}) -> #{ret_text}"

    quote do
      @doc "Bend: `#{unquote(sig_text)}` (line #{unquote(sig.line)})."
      @spec unquote(fname)(unquote_splicing(types)) :: unquote(ret_spec)
      def unquote(fname)(unquote_splicing(vars)) do
        frame =
          Bendler.Codec.request(
            unquote(index),
            unquote(
              Enum.map(pairs, fn {v, t} -> quote(do: {unquote(v), unquote(Macro.escape(t))}) end)
            )
          )

        Bendler.Codec.check(
          Bendler.result(__bendler_send__(frame), unquote(fname)),
          unquote(Macro.escape(ret_t)),
          unquote(fname)
        )
      end
    end
  end
end
