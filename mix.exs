defmodule CodeMySpec.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_my_spec,
      version: "1.5.26",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() in [:prod, :prod_cli],
      aliases: aliases(),
      deps: deps(),
      compilers: compilers(Mix.env()),
      spex: [pattern: "test/spex/**/*_spex.exs", boundary: CodeMySpecSpex],
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_deps: :app_tree,
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      releases: releases()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: app_module(),
      extra_applications: [:logger, :runtime_tools, :inets]
    ]
  end

  defp app_module do
    if Mix.env() in [:dev_cli, :prod_cli, :cli_demo],
      do: {CodeMySpecLocalWeb.Application, []},
      else: {CodeMySpecWeb.Application, []}
  end

  # Specifies which paths to compile per environment.
  # Release modules (Burrito steps) only compile in prod_cli.
  defp elixirc_paths(:test), do: ["lib", "test/support", ".code_my_spec/content"]
  defp elixirc_paths(:dev_cli), do: ["lib", "lib_cli"]
  defp elixirc_paths(:prod_cli), do: ["lib", "lib_cli"]
  defp elixirc_paths(:cli_demo), do: ["lib", "lib_cli"]
  defp elixirc_paths(_), do: ["lib"]

  # :spex compiler only needed in test (compiles BDD spec files for Boundary)
  defp compilers(:test),
    do: [:boundary, :diagnostics, :phoenix_live_view, :erlang, :elixir, :spex, :app]

  defp compilers(_), do: [:boundary, :diagnostics, :phoenix_live_view, :erlang, :elixir, :app]

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
      {:phoenix_live_reload, "~> 1.2", only: [:dev, :dev_cli, :cli_demo, :demo]},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() in [:dev, :dev_cli, :cli_demo, :demo]},
      {:tailwind, "~> 0.3", runtime: Mix.env() in [:dev, :dev_cli, :cli_demo, :demo]},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.21"},
      {:req, "~> 0.5.15"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Added by codemyspec
      {:ex_cli_vcr, git: "https://github.com/johns10/ex_cli_vcr", branch: "main", only: [:test]},
      {:sexy_spex, git: "https://github.com/Code-My-Spec/spex.git", branch: "feature/reusable-givens", only: [:dev, :dev_cli, :test]},
      {:client_utils, "~> 0.1.19"},
      {:credo, "~> 1.7.13"},
      {:sobelow, "~> 0.14.1"},
      {:boundary, "~> 0.10.4"},
      {:code_my_spec_generators, "~> 0.1.0", only: :dev},

      # Normal deps
      {:file_system, "~> 1.0"},
      {:mox, "~> 1.2"},
      {:meck, "~> 0.9", only: [:test]},
      {:req_cassette, "~> 0.6.0", only: :test},
      {:paper_trail, "~> 1.1"},
      {:anubis_mcp, github: "zoedsoupe/anubis-mcp", branch: "main"},
      {:oban, "~> 2.19.4"},
      {:briefly, "~> 0.5.1"},
      {:nimble_csv, "~> 1.2"},
      {:ex_oauth2_provider, "~> 0.5.7"},
      {:earmark, "~> 1.4"},
      {:mdex, "~> 0.5"},
      {:mdex_mermaid, "~> 0.3"},
      {:floki, "~> 0.38"},
      {:wallaby, "~> 0.30", runtime: false, only: :test},
      {:yaml_elixir, "~> 2.11"},
      {:faker, "~> 0.18", only: [:test]},
      {:dir_walker, "~> 0.0.8"},
      {:assent, "~> 0.3.1"},
      {:cloak_ecto, "~> 1.3.0"},
      {:git_cli, "~> 0.3.0"},
      {:dotenvy, "~> 1.1.0"},
      {:google_api_analytics_admin, "~> 0.26.0"},
      {:recase, "~> 0.8"},
      {:uuid, "~> 1.1.8"},
      {:inflex, "~> 2.1.0"},
      {:oauth2, "~> 2.0"},
      {:web_push_elixir, "~> 0.5"},
      {:slipstream, "~> 1.1"},

      # S3 uploads
      {:ex_aws, "~> 2.6"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},

      # Embeddings
      {:ortex, "~> 0.1", only: [:dev_cli, :prod_cli, :cli_demo]},
      {:tokenizers, "~> 0.5", only: [:dev_cli, :prod_cli, :cli_demo]},
      {:nx, "~> 0.9", only: [:dev_cli, :prod_cli, :cli_demo]},
      {:sqlite_vec, "~> 0.1.0", only: [:dev_cli, :prod_cli, :cli_demo]},

      # CLI release
      {:burrito,
       github: "Code-My-Spec/burrito",
       ref: "d44eb28befa146f1c12f6b7b4a2cbc598b3c9686",
       only: [:dev_cli, :prod_cli, :cli_demo],
       runtime: false,
       override: true},
      {:optimus, "~> 0.5", only: [:dev_cli, :prod_cli, :cli_demo]}
    ]
  end

  defp releases do
    [
      code_my_spec: [
        overlays: "rel/overlays"
      ]
    ] ++ cli_release()
  end

  defp cli_release do
    if Mix.env() == :prod_cli do
      [
        code_my_spec_cli: [
          steps: [:assemble, &copy_bcrypt_nif_dll/1, :tar]
        ]
      ]
    else
      []
    end
  end

  # bcrypt_elixir's Makefile names its NIF `bcrypt_nif.so` on every OS, but the
  # Windows BEAM appends `.dll` when loading a NIF — so on Windows it never finds
  # the lib, bcrypt's `on_load` aborts, and the whole app fails to boot. Every
  # other NIF in the release is correctly `.dll`. Copy the (already-PE) `.so` to
  # `.dll` alongside it. Runs before `:tar`, so both the tarball and the
  # MSI-harvested release folder pick it up. Windows-only; on macOS/Linux the
  # `.so` name is already correct.
  defp copy_bcrypt_nif_dll(release) do
    if match?({:win32, _}, :os.type()) do
      release.path
      |> Path.join("lib/bcrypt_elixir-*/priv/bcrypt_nif.so")
      |> Path.wildcard()
      |> Enum.each(fn so -> File.cp!(so, Path.rootname(so) <> ".dll") end)
    end

    release
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
