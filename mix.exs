defmodule AgenticRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :agentic_runtime,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:sagents, "~> 0.7.0"},
      {:langchain,
       github: "nelsonkopliku/langchain",
       ref: "313774ab431176c895c98e4dc7490f12d35d3409",
       override: true},
      {:phoenix, "~> 1.7.14"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0", only: [:dev, :test]},
      {:mox, "~> 1.2", only: :test},
      {:faker, "~> 0.18", only: :test}
    ]
  end
end
