defmodule CodeMySpec.MixProject do
  use Mix.Project

  def project do
    [
      app: :code_my_spec,
      version: version(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() in [:prod, :harness, :desktop],
      aliases: aliases(),
      deps: deps(),
      compilers: compilers(Mix.env()),
      # sexy_spex's own docs require this: without it, a bare `mix spex`
      # compiles under :dev instead of :test, missing test/support paths.
      # `cms.eval` is `mix spex` with one tag included, so it needs the same
      # environment for the same reason.
      preferred_cli_env: [spex: :test, reset_onboarding: :desktop],
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
      releases: releases(),
      desktop_package: desktop_package()
    ]
  end

  # desktop_deployment's installer metadata (bb8bc042).
  defp desktop_package do
    [
      name: "CodeMySpec",
      name_long: "CodeMySpec",
      company: "CodeMySpec",
      description: "CodeMySpec desktop",
      description_long:
        "Requirements-driven development harness, with its server on this machine",
      icon: "priv/static/images/logo-300.png",
      category_macos: "public.app-category.developer-tools",
      identifier: "com.codemyspec.desktop",
      beam_app_name: "code_my_spec"
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
    cond do
      Mix.env() == :harness ->
        {CmsHarness.Application, []}

      Mix.env() == :desktop ->
        {CodeMySpecDesktop.Application, []}

      true ->
        {CodeMySpecWeb.Application, []}
    end
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support", ".code_my_spec/content"]
  # Modules that `use` the desktop-only `desktop` dependency.
  defp elixirc_paths(:desktop), do: ["lib", "lib_desktop"]
  defp elixirc_paths(_), do: ["lib"]

  # The version is git's (John, 2026-10-04): a promotion tags the commit the gate
  # certified and commits nothing, so there is no literal to bump here.
  #
  #   * on a `vX.Y.Z` tag: "X.Y.Z"
  #   * N commits past it: "X.Y.Z+N.gSHA" — build metadata, so it still parses
  #     and sorts with the release it came from
  #   * `CMS_VERSION` overrides both, for builds with no `.git` (the Docker image)
  #   * no git, or no tag reachable: "0.0.0-dev"
  defp version do
    case System.get_env("CMS_VERSION") do
      blank when blank in [nil, ""] -> git_version() || "0.0.0-dev"
      version -> version
    end
  end

  defp git_version do
    args = ["describe", "--tags", "--long", "--match", "v[0-9]*.[0-9]*.[0-9]*"]

    case System.cmd("git", args, cd: __DIR__, stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> from_describe()
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp from_describe(described) do
    case Regex.run(~r/^v(\d+\.\d+\.\d+)-(\d+)-(g[0-9a-f]+)$/, described) do
      [_, version, "0", _sha] -> version
      [_, version, count, sha] -> "#{version}+#{count}.#{sha}"
      nil -> nil
    end
  end

  defp drop_stale_app(_args) do
    app = Path.join(Mix.Project.compile_path(), "code_my_spec.app")

    with {:ok, [{:application, _app, properties}]} <- :file.consult(app),
         vsn when is_list(vsn) <- properties[:vsn],
         true <- List.to_string(vsn) != version() do
      File.rm(app)
    end

    :ok
  end

  # :spex compiler only needed in test (compiles BDD spec files for Boundary)
  #
  # `:diagnostics` first. Mix runs after-compiler hooks last-registered first,
  # so whichever registers first writes the diagnostics file last — after
  # Boundary has added its findings. With `:boundary` first, every Boundary
  # warning reached stdout and never the file the compiler analyzer reads, and
  # 24 of them landed on main past a gate that saw zero.
  defp compilers(:test),
    do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app]

  defp compilers(_), do: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :app]

  # Specifies your project dependencies.
  # mix archive.install hex phx_new 1.8.0-rc.4
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # The agent loop, in the BEAM. Replaces running `pi` as a detached OS
      # process: an agent is a supervised GenServer, so sending it a message is
      # a call rather than a held stdin pipe, and stopping it is termination
      # rather than signalling a process group across a reboot.
      # Our fork of 0.13.0: Codex tool arguments that do not decode go back to
      # the model to resend instead of failing the turn. Overrides the Hex
      # requirement alloy_claude_code declares.
      {:alloy,
       git: "https://github.com/Code-My-Spec/alloy.git", branch: "cms-0.13", override: true},
      # The "claude-code" provider (`CmsHarness.Agents.Provider`). Upstream
      # deferred it, so it is its own package.
      {:alloy_claude_code,
       git: "https://github.com/Code-My-Spec/alloy_claude_code.git", branch: "main"},

      # Phoenix default deps
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.1", override: true},
      {:phoenix_ecto, "~> 4.7"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.18"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: [:dev, :demo]},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      # Resizable panes for the agent-conversation screen. Replaces the
      # hand-rolled PanelResize/PanelSplit/PanelHeight hooks, whose one
      # ResizeObserver addition locked up mobile Safari — a maintained
      # library is less to keep re-debugging by hand.
      {:live_pane, "~> 0.6.6"},
      {:live_flow, "== 0.2.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() in [:dev, :demo]},
      {:tailwind, "~> 0.3", runtime: Mix.env() in [:dev, :demo]},
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
      {:sexy_spex,
       git: "https://github.com/Code-My-Spec/spex.git",
       branch: "feature/reusable-givens",
       only: [:dev, :test]},
      # git rather than hex, so the harness and the library it shares a contract
      # with move together. `Onboarding.databases/2` lists the partitions and
      # `TestDatabase.partition_for/2` uses them; a release boundary between the
      # two means a window where the harness runs a suite against a database
      # nothing told anyone to create.
      {:client_utils, git: "https://github.com/Code-My-Spec/client_utils.git", branch: "main"},
      {:credo, "== 1.7.19"},
      {:ex_slop, "== 0.4.5", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1"},
      {:boundary, "~> 0.10.4"},
      # `code_my_spec_generators` is deliberately NOT a dependency here. Every
      # `cms_gen.*` reference in this repo is a string — prompt text in
      # `AgentTasks.CodeGeneration`, the scaffold script, docs — and the one
      # place that shells a generator (`Provisioning.Widget`) runs it through
      # `Environments.cmd/4` in the *provisioned* project, which carries its
      # own copy. Depending on it here bought nothing and dragged the whole
      # web stack forward on every resolve.

      # Normal deps
      {:file_system, "~> 1.0"},
      {:mox, "~> 1.2"},
      # Only here because ex_cli_vcr needs it to patch System.cmd/3; nothing in
      # this app calls :meck directly. Tracks ex_cli_vcr's requirement.
      {:meck, "~> 1.2", only: [:test]},
      # Fork, until lostbean/req_cassette#7 lands. 0.6.2 records by building a
      # passthrough with `adapter: &Req.Steps.run_finch/1`, which Req 0.7
      # replaced with the `Req.Finch` module — so recording raises and replay
      # does not, and the whole devops suite went on replaying happily while no
      # new cassette could be written.
      {:req_cassette, github: "johns10/req_cassette", branch: "req-0.7-adapter", only: :test},
      # `mix bench.graph`. Test-only on purpose: the dev server runs from a
      # working copy, and a new application in :dev is not hot-reloadable — it
      # takes the running server down until someone restarts it.
      {:benchee, "~> 1.4", only: :test},
      {:paper_trail, "~> 1.1"},
      {:anubis_mcp, "~> 1.14"},
      {:oban, "~> 2.19.4"},
      {:briefly, "~> 0.5.1"},
      {:nimble_csv, "~> 1.2"},
      {:ex_oauth2_provider, "~> 0.5.7"},
      {:earmark, "~> 1.4"},
      {:floki, "~> 0.38"},
      # The Lua VM code mode runs agent scripts in (story 970). A Lua 5.3 VM
      # written in Elixir — no NIFs and no C, which is what makes it safe
      # inside the Burrito binary after MDEx's NIF crashed the BEAM on Windows.
      #
      # Not Amber's `~> 0.4`, for two reasons. The resource limits code mode
      # depends on (`max_instructions`, `max_call_depth`, `max_string_bytes`)
      # arrived in 1.0. And 0.4 was a wrapper over the Erlang `luerl`; 1.0 is
      # its own VM and drops that dependency, so there is no NIF-free claim to
      # re-check at a layer below this one.
      {:lua, "~> 1.0"},
      # The desktop build's native window (bb8bc042): elixir-desktop driving
      # desktop_webview's host (WKWebView / WebView2), no wx. Pinned to commits:
      # Hex `desktop` is from 2024 and desktop_webview is unpublished.
      {:desktop,
       github: "elixir-desktop/desktop",
       ref: "f736ff479e415f1da0cc36de7d1e26e8e3b5b976",
       only: :desktop,
       override: true},
      {:desktop_webview,
       github: "elixir-desktop/webview",
       ref: "626b270cdcc133fb05f84c12ee98f1cfae009a8a",
       only: :desktop},
      {:desktop_deployment,
       github: "elixir-desktop/deployment",
       ref: "9d4305715259c0be2e421022c3deba29fe7117dc",
       only: :desktop,
       runtime: false},
      {:yaml_elixir, "~> 2.11"},
      {:dir_walker, "~> 0.0.8"},
      {:assent, "~> 0.3.1"},
      {:cloak_ecto, "~> 1.3.0"},
      {:dotenvy, "~> 1.1.0"},
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
      #
      # No `only:` — the embeddings rework (577de9bb) moves inference onto
      # the server (OrtexServing, lib/code_my_spec/embeddings/), so :dev and
      # :prod need Ortex/Tokenizers/Nx now too. They were CLI-only while
      # only the packaged binary embedded anything.
      {:ortex, "~> 0.1"},
      {:tokenizers, "~> 0.5"},
      {:nx, "~> 0.9"},
      {:flame, "~> 0.1"},

      # Harness release
      {:burrito,
       github: "Code-My-Spec/burrito",
       ref: "d44eb28befa146f1c12f6b7b4a2cbc598b3c9686",
       only: [:harness],
       runtime: false,
       override: true}
    ]
  end

  defp releases do
    [
      code_my_spec: [
        overlays: "rel/overlays",
        # The desktop build ships as a .dmg / NSIS installer around the native
        # webview host (CodeMySpecDesktop.Installer).
        steps:
          if(Mix.env() == :desktop,
            do: [:assemble, &copy_bcrypt_nif_dll/1, &CodeMySpecDesktop.Installer.step/1],
            else: [:assemble]
          )
      ]
    ] ++ harness_release()
  end

  # The harness release: the brew formula and the MSI both run `bin/cms_harness`.
  defp harness_release do
    if Mix.env() == :harness do
      [
        cms_harness: [
          steps: [
            :assemble,
            &copy_bcrypt_nif_dll/1,
            &copy_onnxruntime_dll/1,
            &copy_mcp_relay/1,
            :tar
          ]
        ]
      ]
    else
      []
    end
  end

  # Put the bundled runtime beside erl.exe so Windows finds it before the
  # incompatible Windows ML runtime in System32. Run before tar/MSI packaging.
  defp copy_onnxruntime_dll(release), do: copy_onnxruntime_dll(release, :os.type())

  @doc false
  def copy_onnxruntime_dll(release, {:win32, _}) do
    bin =
      case Path.wildcard(Path.join(release.path, "erts-*/bin")) do
        [bin] -> bin
        _ -> Mix.raise("Expected one bundled ERTS bin directory for Windows ONNX Runtime")
      end

    dlls = Path.wildcard(Path.join(release.path, "lib/ortex-*/priv/native/onnxruntime*.dll"))

    unless Enum.any?(dlls, &(Path.basename(&1) == "onnxruntime.dll")) do
      Mix.raise(
        "Missing bundled onnxruntime.dll beside the ortex NIF; refusing Windows harness release"
      )
    end

    Enum.each(dlls, &File.cp!(&1, Path.join(bin, Path.basename(&1))))
    release
  end

  def copy_onnxruntime_dll(release, _os), do: release

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
      # `cms.eval` is `mix spex` with one tag included, so it needs the same
      # environment for the same reason.
      preferred_envs: [
        spex: :test,
        agent_test: :test,
        "cms.eval": :test,
        "cms.spex": :test,
        reset_onboarding: :desktop
      ]
    ]
  end

  defp aliases do
    [
      # The version comes from git, and `compile.app` rewrites the `.app` only
      # when an mtime moves — a new tag moves none, so the running app would
      # report the version it was first compiled at. A stale `.app` is dropped
      # first so it is regenerated with the current one.
      compile: [&drop_stale_app/1, "compile"],
      # The migration check first, because `mix spex` loads no test helper and
      # therefore never ran it. A stale worktree database surfaced as
      # `ERROR 42703 (undefined_column)` inside a `given_` step, naming no
      # migration, and cost a full diagnosis twice in one night (40b6424d).
      #
      # An alias step rather than teaching the `../spex` fork to load a helper:
      # that changes how every spex run boots, in a fork shared by two repos,
      # and the ordering against its own `ExUnit.start/1` wants care. This is
      # one query in front of a task that was already an alias.
      spex: [
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "cms.check_test_migrations",
        # Not `"spex --quiet"`. `--quiet` was never a switch this task's own
        # `OptionParser.parse/2` declares — quiet-by-default already comes
        # from the absence of `--verbose` (`configure_spex_mode/1`), read
        # unconditionally. Passing it did nothing except get eaten:
        # `OptionParser.parse(["--quiet", "test/spex/foo_spex.exs"], ...)`
        # returns `{[quiet: "test/spex/foo_spex.exs"], [], []}` — the file
        # path becomes `--quiet`'s own inferred value, `files` comes back
        # empty, and `mix spex <path>` silently ran the whole suite instead
        # of the one file named (f600a617).
        "spex"
      ],
      # Same shape as `spex` above: a refusal in front of a task that was already
      # an alias. `mix ecto.migrate` runs `priv/repo/migrations` whatever MIX_ENV
      # says, so under a SQLite environment it points the Postgres set at a
      # database that cannot take it and fails as if the DDL were broken
      # (02ff6d6b). Self-referencing alias — Mix invokes the real task.
      "ecto.migrate": ["cms.guard_cli_migrate", "ecto.migrate"],
      # Phoenix generates this and this project had lost it, which is how half
      # the analyzer runs came to fail. `mix test` is what the exunit analyzer
      # shells (`Tests.execute/2`), and each working copy owns its own
      # `MIX_TEST_PARTITION` database — so with no alias, one checkout landing a
      # migration left every other checkout's analyzer database behind, its
      # suite refusing to run, and its findings replaying stale forever because
      # nothing could ever re-validate them. Nobody could see why: the reason
      # was in the analyzer's stats, and the agent saw "failed, 0 problems".
      #
      # `cms.new` ships it (templates/phx_single/mix.exs.eex); only this repo
      # dropped it while the aliases were reworked around `agent_test`.
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
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
