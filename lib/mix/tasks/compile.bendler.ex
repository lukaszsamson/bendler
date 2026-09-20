defmodule Mix.Tasks.Compile.Bendler do
  @shortdoc "Builds the Bend artifacts the project's `use Bendler` modules requested"
  @moduledoc """
  Runs after `:elixir` when the project lists it:

      compilers: Mix.compilers() ++ [:bendler]

  Each `use Bendler` module records a build request while compiling; this
  task builds the requests into `priv/bendler/`, skipping those whose
  fingerprint (sources, imports, shim, C, toolchain) is unchanged.
  `--force` rebuilds everything. `mix bendler.clean` removes the artifacts.
  """
  use Mix.Task.Compiler

  @impl true
  def run(args) do
    force = "--force" in args
    requests = Bendler.Build.requests()

    Enum.each(requests, &Bendler.Build.build!(&1, force: force))

    if requests == [], do: {:noop, []}, else: {:ok, []}
  end

  @impl true
  def clean, do: Mix.Task.run("bendler.clean")
end
