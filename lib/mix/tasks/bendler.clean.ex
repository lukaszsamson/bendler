defmodule Mix.Tasks.Bendler.Clean do
  @shortdoc "Removes built Bend artifacts so the next compile rebuilds them"
  @moduledoc """
  Removes this application's `priv/bendler/` artifacts and build directories.
  The build requests the `use Bendler` modules recorded are kept, so the next
  `mix compile` rebuilds without recompiling the Elixir modules.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    app = to_string(Mix.Project.config()[:app])
    base = Path.join([Mix.Project.build_path(), "bendler", app])

    for dir <-
          File.ls(base)
          |> then(fn
            {:ok, l} -> l
            _ -> []
          end),
        dir != "requests" do
      _ = File.rm_rf!(Path.join(base, dir))
    end

    _ = File.rm_rf!(Path.join([Mix.Project.app_path(), "priv", "bendler"]))
    Mix.shell().info("bendler: cleaned #{app}")
  end
end
