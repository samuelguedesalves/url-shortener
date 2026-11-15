defmodule WriteApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :write_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {WriteApi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:shortener_core, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Present in every env (the prod image builds the assets); started only in dev.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev}
    ]
  end

  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind write_api", "esbuild write_api"],
      "assets.deploy": [
        "tailwind write_api --minify",
        "esbuild write_api --minify",
        "phx.digest"
      ]
    ]
  end
end
