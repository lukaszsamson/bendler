defmodule Bendler.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukaszsamson/bendler"

  def project do
    [
      app: :bendler,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test"] ++ Path.wildcard("demos/*/test"),
      test_ignore_filters: [~r{test/(support|fixtures)/}],
      compilers: Mix.compilers() ++ [:bendler],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Call Bend code from Elixir: a generated port (or experimental NIF) binding for a Bend file.",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:mix, :crypto],
        flags: [:missing_return, :extra_return, :unmatched_returns]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"] ++ Path.wildcard("demos/*/lib")
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:telemetry, "~> 1.3"},
      {:nimble_csv, "== 1.3.0", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Bend" => "https://bend-lang.org"},
      files: ~w(lib priv/c priv/bend mix.exs README.md CHANGELOG.md LICENSE docs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/API.md",
        "docs/TYPES.md",
        "docs/CONTRACTS.md",
        "docs/DESIGN.md",
        "docs/NIF.md",
        "docs/VALIDATION.md",
        "docs/ROADMAP.md"
      ]
    ]
  end
end
