defmodule Consumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :consumer,
      version: "0.1.0",
      elixir: "~> 1.16",
      compilers: Mix.compilers() ++ [:bendler],
      deps: [{:bendler, path: System.fetch_env!("BENDLER_ROOT")}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
