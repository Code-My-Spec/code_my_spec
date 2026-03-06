defmodule CodeMySpec.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_my_spec,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: compilers(Mix.env()),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_deps: :app_tree,
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {CodeMySpecWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support", ".code_my_spec/content"]
  defp elixirc_paths(_), do: ["lib"]

  # :spex compiler only needed in test (compiles BDD spec files for Boundary)
  defp compilers(:test),
    do: [:diagnostics, :phoenix_live_view, :erlang, :elixir, :spex, :app]

  defp compilers(_), do: [:diagnostics, :phoenix_live_view, :erlang, :elixir, :app]

  # Specifies your project dependencies.
  # mix archive.install hex phx_new 1.8.0-rc.4
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Phoenix default deps
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.1", override: true},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.18"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Added by codemyspec
      {:ex_cli_vcr, git: "https://github.com/johns10/ex_cli_vcr", branch: "main"},
      {:sexy_spex, git: "https://github.com/Code-My-Spec/spex"},
      {:client_utils, path: "../client_utils"},
      {:credo, "~> 1.7.13"},
      {:sobelow, "~> 0.14.1"},
      {:boundary, "~> 0.10.4"},

      # Normal deps
      {:file_system, "~> 1.0"},
      {:mox, "~> 1.2"},
      {:meck, "~> 0.9"},
      {:exvcr, "~> 0.15", only: :test},
      {:paper_trail, "~> 1.1"},
      {:hermes_mcp, github: "johns10/hermes-mcp", branch: "fix/stdio-batch-messages"},
      {:oban, "~> 2.19.4"},
      {:briefly, "~> 0.5.1"},
      {:ex_oauth2_provider, "~> 0.5.7"},
      {:earmark, "~> 1.4"},
      {:floki, "~> 0.38"},
      {:yaml_elixir, "~> 2.11"},
      {:faker, "~> 0.18"},
      {:dir_walker, "~> 0.0.8"},
      {:assent, "~> 0.3.1"},
      {:cloak_ecto, "~> 1.3.0"},
      {:git_cli, "~> 0.3.0"},
      {:dotenvy, "~> 1.1.0"},
      {:google_api_analytics_admin, "~> 0.26.0"},
      {:recase, "~> 0.8"},
      {:oapi_github, "~> 0.3.3"},
      {:httpoison, "~> 2.0"},
      {:uuid, "~> 1.1.8"},
      {:inflex, "~> 2.1.0"},
      {:oauth2, "~> 2.0"},
      {:web_push_elixir, "~> 0.5"},
      {:slipstream, "~> 1.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  def cli do
    [
      preferred_envs: [spex: :test]
    ]
  end

  defp aliases do
    [
      spex: ["spex --quiet"],
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind code_my_spec", "esbuild code_my_spec"],
      "assets.deploy": [
        "tailwind code_my_spec --minify",
        "esbuild code_my_spec --minify",
        "phx.digest"
      ],
      sobelow: ["sobelow --skip"]
    ]
  end
end
