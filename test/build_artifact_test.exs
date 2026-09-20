defmodule Bendler.BuildArtifactTest do
  use ExUnit.Case, async: true

  alias Bendler.Build

  test "artifact paths are explicitly isolated by Mix environment and target" do
    scope = Path.join(["bendler", to_string(Mix.target()), to_string(Mix.env())])

    assert Build.artifact_relative_path("worker", :port) == Path.join([scope, "worker"])
    assert Build.artifact_relative_path("worker", :nif) == Path.join([scope, "worker.so"])

    assert Build.launcher_path(:bendler, "worker") ==
             Path.join(Build.artifact_dir(:bendler), "bendler_launcher")

    assert Build.build_scope(:bendler) =~
             Path.join([to_string(Mix.target()), to_string(Mix.env())])
  end

  @tag timeout: 120_000
  test "simultaneous builders publish one complete port artifact pair" do
    name = "concurrent_#{System.unique_integer([:positive])}"

    opts = %{
      module: Bendler.Test.RecordOnlyPort,
      app: :bendler,
      source: Path.expand("bend/composite.bend"),
      backend: :port,
      name: name,
      exports: ["rec_echo"]
    }

    results =
      1..2
      |> Task.async_stream(fn _ -> Build.build!(opts) end, max_concurrency: 2, timeout: 90_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [List.first(results)]
    assert File.regular?(Build.artifact_path(:bendler, name, :port))
    assert File.regular?(Build.launcher_path(:bendler, name))
  end
end
