defmodule Mix.Tasks.Bendler.Clean do
  @shortdoc "Removes built Bend artifacts so the next compile rebuilds them"
  @moduledoc """
  Removes only this Mix environment and target's artifacts and build
  directories. The build requests the `use Bendler` modules recorded are
  kept, so the next `mix compile` rebuilds without recompiling the Elixir
  modules.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    app = Mix.Project.config()[:app]
    Bendler.Build.clean!(app)
    Mix.shell().info("bendler: cleaned #{app}")
  end
end
