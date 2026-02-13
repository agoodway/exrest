defmodule PgRest.MixProject do
  use Mix.Project

  def project do
    [
      app: :pg_rest,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["ecto.create --quiet -r PgRest.Integration.Repo", "test"],
      quality: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "doctor",
        "dialyzer"
      ]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:telemetry, "~> 1.0"},
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22.0", only: :dev, runtime: false},

      # Integration test deps
      {:supabase_potion, "~> 0.7.2", only: :test},
      {:supabase_postgrest, "~> 1.2", only: :test},
      {:bandit, "~> 1.0", only: :test}
    ]
  end
end
