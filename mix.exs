defmodule CodeMySpec.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_my_spec,
      version: "1.8.2",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() in [:prod, :prod_cli],
      aliases: aliases(),
      deps: deps(),
      compilers: compilers(Mix.env()),
      spex: [pattern: "test/spex/**/*_spex.exs", boundary: CodeMySpecSpex],
      # _spex.exs files are a separate suite run by `mix spex` (which loads
      # them via Path.wildcard, not these filters). Declare them ignored so
      # `mix test` doesn't flag them as stray/mistyped test files.
      test_ignore_filters: [~r/_spex\.exs$/],
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
    if Mix.env() in [:dev_cli, :prod_cli, :cli_demo, :dev_sprite],
      do: {CodeMySpecLocalWeb.Application, []},
      else: {CodeMySpecWeb.Application, []}
  end

  # Specifies which paths to compile per environment.
  # Release modules (Burrito steps) only compile in prod_cli.
  defp elixirc_paths(:test), do: ["lib", "test/support", ".code_my_spec/content"]
  defp elixirc_paths(:dev_cli), do: ["lib", "lib_cli"]
  defp elixirc_paths(:dev_sprite), do: ["lib", "lib_cli"]
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
      {:req, "~> 0.7"},
      {:req_llm, "~> 1.0"},
      # req_llm 1.18 matches on `%Finch.Pool{}` and `Finch.Request`'s
      # `:pool_tag`, which only exist from finch 0.22. `req` asks for `~> 0.17`,
      # so resolution was free to pick 0.21 — and did. The build only appeared
      # to work because `_build` held artifacts compiled against a finch that
      # had them; a clean build has never succeeded.
      {:finch, "~> 0.23", override: true},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Already present transitively; declared because the preview proxy pipes
      # a LiveView socket upstream through it, and a direct use should not rest
      # on someone else's dependency staying put.
      {:mint_web_socket, "~> 1.0"},

      # Added by codemyspec
      {:ex_cli_vcr, git: "https://github.com/johns10/ex_cli_vcr", branch: "main", only: [:test]},
      {:sexy_spex, git: "https://github.com/Code-My-Spec/spex.git", branch: "feature/reusable-givens", only: [:dev, :dev_cli, :test]},
      {:client_utils, "~> 0.1.22"},
      {:credo, "~> 1.7.13"},
      {:sobelow, "~> 0.14.1"},
      {:boundary, "~> 0.10.4"},
      {:code_my_spec_generators, "~> 0.1.0", only: :dev},

      # Normal deps
      {:file_system, "~> 1.0"},
      {:mox, "~> 1.2"},
      # Only here because ex_cli_vcr needs it to patch System.cmd/3; nothing in
      # this app calls :meck directly. Tracks ex_cli_vcr's requirement.
      {:meck, "~> 1.2", only: [:test]},
      {:req_cassette, "~> 0.6.2", only: :test},
      # `mix bench.graph`. Test-only on purpose: the dev server runs from a
      # working copy, and a new application in :dev is not hot-reloadable — it
      # takes the running server down until someone restarts it.
      {:benchee, "~> 1.4", only: :test},
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
      {:yaml_elixir, "~> 2.11"},
      {:dir_walker, "~> 0.0.8"},
      {:assent, "~> 0.3.1"},
      {:cloak_ecto, "~> 1.3.0"},
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
      {:ortex, "~> 0.1", only: [:dev_cli, :prod_cli, :cli_demo, :dev_sprite]},
      {:tokenizers, "~> 0.5", only: [:dev_cli, :prod_cli, :cli_demo, :dev_sprite]},
      {:nx, "~> 0.9", only: [:dev_cli, :prod_cli, :cli_demo, :dev_sprite]},
      {:sqlite_vec, "~> 0.1.0", only: [:dev_cli, :prod_cli, :cli_demo]},

      # CLI release
      {:burrito,
       github: "Code-My-Spec/burrito",
       ref: "d44eb28befa146f1c12f6b7b4a2cbc598b3c9686",
       only: [:dev_cli, :prod_cli, :cli_demo, :dev_sprite],
       runtime: false,
       override: true},
      {:optimus, "~> 0.5", only: [:dev_cli, :prod_cli, :cli_demo, :dev_sprite]}
    ]
  end

  defp releases do
    [
      code_my_spec: [
        overlays: "rel/overlays"
      ]
    ] ++ cli_release()
  end

  # dev_sprite ships the same release as prod_cli — a sprite is the CLI harness,
  # just compiled against Postgres instead of SQLite (see config/dev_sprite.exs).
  # The adapter is a compile-time choice (DocEmbedding keys its column types off
  # it), so a sprite needs its own build rather than a runtime flag on the
  # published binary.
  defp cli_release do
    if Mix.env() in [:prod_cli, :dev_sprite] do
      [
        code_my_spec_cli: [
          steps: [:assemble, &copy_bcrypt_nif_dll/1, &copy_mcp_relay/1, :tar]
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

  # cms-mcp-relay is the standalone Go stdio<->HTTP MCP bridge Claude Code spawns
  # (instead of booting the BEAM via `cms start`). It's cross-compiled to
  # relay/cms-mcp-relay[.exe] by the CI before `mix release`; this step drops it
  # into the release bin/ so it ships in the same tarball every packager consumes
  # (brew symlinks it; the MSI harvests bin/). Skipped if absent so a plain
  # server build still works.
  defp copy_mcp_relay(release) do
    exe = if match?({:win32, _}, :os.type()), do: "cms-mcp-relay.exe", else: "cms-mcp-relay"
    src = Path.join([File.cwd!(), "relay", exe])

    if File.exists?(src) do
      dst = Path.join([release.path, "bin", exe])
      File.cp!(src, dst)
      File.chmod!(dst, 0o755)
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
      preferred_envs: [spex: :test, agent_test: :test]
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
