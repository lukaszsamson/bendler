defmodule Bendler.Build do
  @moduledoc """
  Builds a Bend module into a NIF library or a port executable.

  The steps: parse the exports, write the shim, the specs header and the
  effect sources into a build directory, run `bend shim.bend -o shim.c`,
  then `clang` the C (as a `-shared` library with the NIF glue, or as an
  executable). The artifact is built to a staging path and renamed into the
  application's `priv/bendler/` only on success, so a failed rebuild keeps
  the previous artifact. A fingerprint of every input skips rebuilds.

  Build requests are recorded per application under the build path, so a
  dependency's modules are built by the dependency's own compile, never by
  the application depending on it.
  """

  alias Bendler.{Gen, Sig}
  require Logger

  @supported_bend "bend 2.0.20"
  @c_files ~w(bendler_common.h bendler_port.h bendler_nif.h bendler_fn.c bendler_arg.c bendler_reply.c
              bendler_fn.js bendler_arg.js bendler_reply.js)

  @type opts :: %{
          module: module,
          app: atom,
          source: Path.t(),
          backend: :nif | :port,
          name: String.t(),
          exports: [String.t()] | nil
        }

  @doc "Whether the project runs the `:bendler` Mix compiler after `:elixir`."
  @spec mix_compiler?() :: boolean
  def mix_compiler?, do: :bendler in (Mix.Project.config()[:compilers] || [])

  @doc "Records a build request for `mix compile.bendler` and returns the exports and datatypes."
  @spec request!(opts) :: {[Sig.t()], Sig.types()}
  def request!(%{name: name} = opts) do
    {sigs, _src, types} = exports!(opts)
    dir = requests_dir()
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name <> ".request"), :erlang.term_to_binary(opts))
    {sigs, types}
  end

  @doc "The build requests recorded by this application's modules (stale ones are dropped)."
  @spec requests() :: [opts]
  def requests do
    requests_dir()
    |> Path.join("*.request")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      req = file |> File.read!() |> :erlang.binary_to_term()

      # never load the module here: its @on_load would look for the artifact being built
      if beam_exists?(req.module) do
        [req]
      else
        _ = File.rm(file)
        []
      end
    end)
  end

  defp beam_exists?(module) do
    File.exists?(Path.join([Mix.Project.compile_path(), "#{module}.beam"]))
  end

  defp requests_dir,
    do: Path.join([Mix.Project.build_path(), "bendler", to_string(app()), "requests"])

  defp app, do: Mix.Project.config()[:app]

  defp exports!(%{module: module, source: source} = opts) do
    src = File.read!(source)
    {sigs, skipped, types} = Sig.parse(src)
    sigs = filter(sigs, opts[:exports], module, skipped)

    for {n, why} <- skipped, opts[:exports] == nil or n in opts[:exports] do
      Logger.debug("bendler: #{inspect(module)} does not export #{n}: #{why}")
    end

    {sigs, src, types}
  end

  @doc "Builds and returns the exports, the datatypes and the artifact path."
  @spec build!(opts, keyword) :: {[Sig.t()], Sig.types(), Path.t()}
  def build!(
        %{module: module, source: source, backend: backend, name: name} = opts,
        build_opts \\ []
      ) do
    {sigs, src, types} = exports!(opts)
    version_gate!()

    build_dir = Path.join([Mix.Project.build_path(), "bendler", to_string(app()), name])
    out_dir = Path.join(priv_dir(), "bendler")
    File.mkdir_p!(build_dir)
    File.mkdir_p!(out_dir)

    artifact = Path.join(out_dir, if(backend == :nif, do: name <> ".so", else: name))
    rel = Path.relative_to(Path.expand(source), build_dir, force: true) |> relativize()
    {shim, specs, bytes_flag} = shim!(rel, sigs, types, source, build_dir)
    c_sources = Enum.map(@c_files, &File.read!(Path.join(c_dir(), &1)))

    glue =
      if backend == :nif,
        do: Gen.nif_glue(File.read!(Path.join(c_dir(), "bendler_nif_glue.c")), module),
        else: ""

    stamp =
      fingerprint({src, imports(source), shim, specs, c_sources, glue, backend, toolchain()})

    stamp_file = Path.join(build_dir, "stamp")

    if not Keyword.get(build_opts, :force, false) and File.exists?(artifact) and
         File.read(stamp_file) == {:ok, stamp} do
      {sigs, types, artifact}
    else
      Logger.info("bendler: building #{inspect(module)} (#{backend}) from #{source}")
      for f <- @c_files, do: File.cp!(Path.join(c_dir(), f), Path.join(build_dir, f))
      File.write!(Path.join(build_dir, "shim.bend"), shim)
      File.write!(Path.join(build_dir, "bendler_specs.h"), specs)
      c_path = Path.join(build_dir, "shim.c")
      _ = File.rm(c_path)
      _ = File.rm(stamp_file)
      run!(bend(), ["shim.bend", "-o", "shim.c"], build_dir)

      # stage under a unique name, then rename: a failed build never
      # replaces the artifact a running system may still be loading
      staged = artifact <> ".building." <> Integer.to_string(System.unique_integer([:positive]))

      gpu = compile!(backend, build_dir, c_path, staged, glue, bytes_flag.(c_path))

      # the runtime looks for its GPU program beside the executable, as <exe>.gpu
      File.rename!(staged, artifact)

      if gpu, do: File.rename!(staged <> ".gpu", artifact <> ".gpu"), else: drop_gpu(artifact)

      File.write!(stamp_file, stamp)
      {sigs, types, artifact}
    end
  end

  # clang builds the emitted C into `staged`: an executable, or a shared
  # library with the NIF glue and the C patched for the BEAM. A program
  # with `!` calls builds its GPU lane too (Metal on macOS, CUDA on Linux
  # when it is installed) and writes the device program as `staged.gpu`,
  # the way `bend -o` does; answers whether it did.
  defp compile!(:port, build_dir, c_path, staged, _glue, bytes_flag) do
    gpu = gpu_lane(c_path)

    run!(
      cc(),
      gpu_flags(gpu) ++
        ~w(-std=c11 -O3 -I. -DBENDLER_TRANSPORT="bendler_port.h") ++
        bytes_flag ++ ["shim.c", "-o", staged, "-lpthread", "-lm"] ++ gpu_libs(gpu),
      build_dir
    )

    if gpu, do: run!(staged, ["--gpu-build"], build_dir)
    gpu != nil
  end

  # a NIF runs `!` calls on the CPU pool: the runtime finds its GPU program
  # beside the executable, which in the BEAM is the VM's own
  defp compile!(:nif, build_dir, c_path, staged, glue, bytes_flag) do
    File.write!(Path.join(build_dir, "shim_nif.c"), Gen.host_in_beam!(File.read!(c_path)))
    File.write!(Path.join(build_dir, "bendler_nif_glue.c"), glue)

    run!(
      cc(),
      ~w(-std=c11 -O3 -shared -fPIC -I. -I#{erts_include()} -DBENDLER_TRANSPORT="bendler_nif.h") ++
        bytes_flag ++
        platform_flags() ++
        ["shim_nif.c", "bendler_nif_glue.c", "-o", staged, "-lpthread", "-lm"],
      build_dir
    )

    false
  end

  # a stale device program of an earlier build must not sit beside a CPU build
  defp drop_gpu(artifact) do
    _ = File.rm(artifact <> ".gpu")
    :ok
  end

  # :metal, :cuda or nil: the GPU lane the emitted C can be built with here
  defp gpu_lane(c_path) do
    bangs? = not Regex.match?(~r/^#define BANGS\s+0$/m, File.read!(c_path))

    cond do
      not bangs? -> nil
      macos?() -> :metal
      File.exists?(Path.join(cuda_home(), "include/nvrtc.h")) -> :cuda
      true -> nil
    end
  end

  defp macos?, do: match?({:unix, :darwin}, :os.type())
  defp cuda_home, do: System.get_env("CUDA_HOME") || "/usr/local/cuda"

  defp gpu_flags(nil), do: []
  defp gpu_flags(:metal), do: ~w(-x objective-c -fobjc-arc -fmodules -DBEND_METAL=1)

  defp gpu_flags(:cuda),
    do: [
      "-DBEND_CUDA=1",
      "-I#{cuda_home()}/include",
      "-L#{cuda_home()}/lib64",
      "-L#{cuda_home()}/lib"
    ]

  defp gpu_libs(:cuda), do: ["-lcuda", "-lnvrtc"]
  defp gpu_libs(_), do: []

  # The prelude (priv/bend/bendler.bend) is written next to the source that
  # uses Bytes, so `import ./bendler.bend as B` resolves; an outdated copy is
  # replaced. Answers the shim's import path for it.
  defp prelude!(source, build_dir) do
    template =
      File.read!(Path.join([to_string(:code.priv_dir(:bendler)), "bend", "bendler.bend"]))

    path = Path.join(Path.dirname(source), "bendler.bend")

    if File.read(path) != {:ok, template} do
      Logger.info("bendler: writing the prelude to #{path}")
      File.write!(path, template)
    end

    Path.relative_to(path, build_dir, force: true) |> relativize()
  end

  # the shim, the specs header and the compiler flags naming the prelude's
  # constructors (a function of the emitted C, known only after bend runs)
  defp shim!(rel, sigs, types, source, build_dir) do
    uses = %{bytes: Gen.uses_bytes?(sigs), data: Gen.uses_data?(sigs)}
    prelude = if uses.bytes or uses.data, do: prelude!(source, build_dir)
    flags = fn c -> if prelude, do: prelude_flags!(c, uses), else: [] end
    {Gen.shim(rel, sigs, prelude, types), Gen.specs_h(sigs, types), flags}
  end

  @dyn_ctors ~w(DU DF DN DS DB DL DK)

  # The C names of the prelude's constructors, as the emitted source spells
  # them (they depend on the import path), for the codec: Bytes when an
  # export carries bytes, every Dyn constructor when one carries a datatype.
  defp prelude_flags!(c_path, uses) do
    c = File.read!(c_path)
    wanted = if(uses.bytes, do: ["BYTES"], else: []) ++ if(uses.data, do: @dyn_ctors, else: [])

    Enum.map(wanted, fn name ->
      case Regex.run(~r/^#define (CID_\S*BENDLER_#{name}) \d+$/m, c) do
        [_, macro] ->
          "-DBENDLER_CID_#{name}=#{macro}"

        nil ->
          raise Bendler.Error,
                "the emitted C has no #{name} constructor of the prelude; is the prelude imported?"
      end
    end)
  end

  defp filter(sigs, nil, _, _), do: sigs

  defp filter(sigs, names, module, skipped) do
    names = Enum.map(names, &to_string/1)
    missing = names -- Enum.map(sigs, & &1.name)
    if missing != [], do: raise(Bendler.Error, cannot_export(module, missing, skipped))
    Enum.filter(sigs, &(&1.name in names))
  end

  defp cannot_export(module, missing, skipped) do
    why =
      Enum.map_join(missing, "; ", fn name ->
        case List.keyfind(skipped, name, 0) do
          {_, reason} -> "#{name}: #{reason}"
          nil -> "#{name}: no such def"
        end
      end)

    "#{inspect(module)} cannot export #{why}"
  end

  # The fingerprint covers everything the artifact depends on: the sources
  # (with the files they import, transitively), the shim and C, and the
  # toolchain (bend and its Base, the C compiler, the target, OTP).
  defp fingerprint(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16()

  @spec imports(Path.t(), [Path.t()]) :: [{Path.t(), binary | :missing}]
  defp imports(source, seen \\ []) do
    dir = Path.dirname(source)

    ~r/^import\s+(\.\.?\/[^\s]+\.bend)/m
    |> Regex.scan(File.read!(source))
    |> Enum.map(fn [_, rel] -> Path.expand(rel, dir) end)
    |> Enum.reject(&(&1 in seen))
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, body} -> [{path, body} | imports(path, [source | seen])]
        _ -> [{path, :missing}]
      end
    end)
  end

  defp toolchain do
    %{
      bend: bend_version(),
      base: cmd_out(bend(), ["base"]),
      cc: cmd_out(cc(), ["--version"]),
      arch: to_string(:erlang.system_info(:system_architecture)),
      erts: to_string(:erlang.system_info(:version))
    }
  end

  defp cmd_out(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> "unknown"
    end
  end

  # The C side depends on runtime internals with no ABI promise: refuse a
  # bend this code was not written against unless explicitly allowed.
  defp version_gate! do
    v = bend_version()

    unless v == @supported_bend or Application.get_env(:bendler, :allow_any_bend, false) do
      raise Bendler.Error,
            "bendler supports #{@supported_bend}, found #{inspect(v)} at #{bend()}; " <>
              "set `config :bendler, allow_any_bend: true` to try anyway"
    end
  end

  defp relativize(path), do: if(String.starts_with?(path, "."), do: path, else: "./" <> path)

  defp run!(cmd, args, dir) do
    case System.cmd(cmd, args, cd: dir, stderr_to_stdout: true) do
      {out, 0} ->
        if out =~ "Error", do: Logger.warning(out)
        :ok

      {out, code} ->
        raise Bendler.Error, "#{cmd} #{Enum.join(args, " ")} failed (#{code}) in #{dir}:\n#{out}"
    end
  end

  @doc "The bend executable: `config :bendler, bend: path`, else `bend` on PATH, else ~/.bend/bin/bend."
  @spec bend() :: Path.t()
  def bend do
    Application.get_env(:bendler, :bend) || System.find_executable("bend") ||
      Path.expand("~/.bend/bin/bend")
  end

  defp bend_version do
    case System.cmd(bend(), ["version"], stderr_to_stdout: true) do
      {v, 0} -> String.trim(v)
      _ -> "unknown"
    end
  rescue
    ErlangError -> "not found"
  end

  defp cc, do: Application.get_env(:bendler, :cc) || System.get_env("CC") || "clang"

  defp c_dir, do: Path.join(:code.priv_dir(:bendler) |> to_string(), "c")

  defp priv_dir, do: Path.join(Mix.Project.app_path(), "priv")

  defp erts_include do
    Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "include"])
  end

  defp platform_flags do
    case :os.type() do
      {:unix, :darwin} -> ["-undefined", "dynamic_lookup"]
      _ -> []
    end
  end
end
