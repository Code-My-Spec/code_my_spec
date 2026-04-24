defmodule CodeMySpec.SetupFixtures do
  @moduledoc """
  Seeds an `InMemoryEnvironment` so named setup step modules evaluate
  `{:ok, :valid}`. Used by BDD specs for Story 124 (Project Setup).

  Additive — `satisfy/2` can be called multiple times to simulate
  incremental completion across a single scenario.

  All writes are relative to `env.cwd` via the `Environments` API, so
  the fixture works against any environment (memory, local, cli).

  ## Cross-cutting invariants

  - Always writes a baseline `mix.exs` on first use (contains
    `app: :my_app`). Most setup steps short-circuit without a parseable
    mix.exs; this guarantees `extract_app_name/1` succeeds.
  - `mix.exs` amendments append snippets idempotently (marker-guarded).
    The resulting file is not compilable Elixir — it only satisfies the
    step evaluators' regex checks. Swap to a template if real
    compilation is ever needed.
  - `TestSupportNamespace` passes when `conn_case.ex`/`data_case.ex`
    are absent. The `satisfy/2` clause for that step is a no-op.
  - `ProjectStructure` satisfies by writing `.keep` files under the
    required directories (InMemoryEnvironment treats a path with
    descendants as an existing directory).
  - `IgnoredPaths` runs `FileSync` + `ComponentSync` on evaluate when
    the scope has an `active_project_id`. This is intentional — specs
    exercise the full sync pipeline against the in-memory env.

  See `.code_my_spec/issues/project-setup/fixtures.md` for the
  complete step→state inventory and break-matrix.
  """

  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  @app_name "my_app"
  @app_mod "MyApp"

  @doc """
  Seed the environment to satisfy every step in `steps`. Returns `:ok`.

  Always writes a baseline `mix.exs` on first call. Safe to call
  multiple times — each step's satisfaction is idempotent.

  Note: Scenarios within a single `spex` block share the in-memory env.
  Call `reset/1` at the start of each scenario that needs a clean slate.
  """
  @spec satisfy(Environment.t(), [module()]) :: :ok
  def satisfy(env, steps) when is_list(steps) do
    ensure_baseline_mix_exs(env)
    Enum.each(steps, &satisfy_step(env, &1))
    :ok
  end

  @doc """
  Wipe every file from the in-memory env's backing store.

  Use at the start of scenarios that need a clean env — scenarios
  share the env across a single spex block otherwise.
  """
  @spec reset(Environment.t()) :: :ok
  def reset(%Environment{type: :memory, ref: %{agent: agent}}) do
    Agent.update(agent, fn _ -> %{} end)
  end

  @doc "App name baked into the baseline mix.exs fixture."
  @spec app_name() :: String.t()
  def app_name, do: @app_name

  @doc "App module name baked into the baseline mix.exs fixture."
  @spec app_mod() :: String.t()
  def app_mod, do: @app_mod

  # --- per-step satisfaction ---

  defp satisfy_step(env, Setup.ApplicationInWeb) do
    Environments.write_file(
      env,
      "lib/#{@app_name}_web/application.ex",
      "defmodule #{@app_mod}Web.Application do\nend\n"
    )
  end

  defp satisfy_step(env, Setup.CodemyspecDeps), do: amend_mix_exs(env, :deps)
  defp satisfy_step(env, Setup.Compilers), do: amend_mix_exs(env, :compilers)
  defp satisfy_step(env, Setup.SpexConfig), do: amend_mix_exs(env, :spex_config)

  defp satisfy_step(env, Setup.TestBoundaries) do
    Environments.write_file(
      env,
      "test/support/#{@app_name}_spex.ex",
      "defmodule #{@app_mod}Spex do\n  use Boundary\nend\n"
    )

    Environments.write_file(
      env,
      "test/support/#{@app_name}_test_boundary.ex",
      "defmodule #{@app_mod}Test do\n  use Boundary\nend\n"
    )
  end

  # Default state is satisfying. Writing nothing keeps the step green.
  defp satisfy_step(_env, Setup.TestSupportNamespace), do: :ok

  defp satisfy_step(env, Setup.SpexCase) do
    Environments.write_file(env, "test/support/#{@app_name}_spex_case.ex", """
    defmodule #{@app_mod}Spex.Case do
      use SexySpex
      import Phoenix.LiveViewTest
    end
    """)
  end

  defp satisfy_step(env, Setup.ProjectStructure) do
    # InMemoryEnvironment treats "path with descendants" as an existing dir.
    Environments.write_file(env, ".code_my_spec/rules/.keep", "")
    Environments.write_file(env, ".code_my_spec/spec/#{@app_name}/.keep", "")
    Environments.write_file(env, ".code_my_spec/spec/#{@app_name}_web/.keep", "")
  end

  defp satisfy_step(env, Setup.IgnoredPaths) do
    Environments.write_file(
      env,
      ".code_my_spec/config.yml",
      "ignored_paths:\n  - lib/#{@app_name}/repo.ex\n"
    )
  end

  defp satisfy_step(env, Setup.AgentsMd) do
    Environments.write_file(env, ".code_my_spec/AGENTS.md", "# Agents\n")
  end

  defp satisfy_step(env, Setup.Rules) do
    Environments.write_file(env, ".code_my_spec/rules/default.md", "# Default Rule\n")
  end

  defp satisfy_step(env, Setup.CredoChecks) do
    Environments.write_file(env, ".credo.exs", """
    %{configs: [%{
      requires: [
        ".code_my_spec/credo_checks/framework/**/*.ex",
        ".code_my_spec/credo_checks/local/**/*.ex"
      ],
      checks: %{extra:
        if(File.exists?(".code_my_spec/credo_checks/framework/checks.exs"),
          do: elem(Code.eval_file(".code_my_spec/credo_checks/framework/checks.exs"), 0),
          else: [])
      }
    }]}
    """)
  end

  defp satisfy_step(env, Setup.ClaudeMd) do
    Environments.write_file(
      env,
      "CLAUDE.md",
      "# CLAUDE\n<!-- code_my_spec:start -->\nmanaged\n<!-- code_my_spec:end -->\n"
    )
  end

  # --- mix.exs baseline + amendments ---

  defp ensure_baseline_mix_exs(env) do
    unless Environments.file_exists?(env, "mix.exs") do
      Environments.write_file(env, "mix.exs", """
      defmodule #{@app_mod}.MixProject do
        use Mix.Project
        def project, do: [app: :#{@app_name}, version: "0.0.1"]
        def application, do: []
        defp deps, do: []
      end
      """)
    end
  end

  defp amend_mix_exs(env, :deps) do
    append_if_missing(env, "mix.exs", "# amendment: deps", """

    # amendment: deps
    # {:credo, "~> 0.0"},
    # {:client_utils, "~> 0.0"},
    # {:sobelow, "~> 0.0"},
    # {:sexy_spex, "~> 0.0"},
    # {:boundary, "~> 0.0"},
    """)
  end

  defp amend_mix_exs(env, :compilers) do
    append_if_missing(
      env,
      "mix.exs",
      "# amendment: compilers",
      "\n# amendment: compilers: [:boundary, :spex]\n"
    )
  end

  defp amend_mix_exs(env, :spex_config) do
    append_if_missing(
      env,
      "mix.exs",
      "# amendment: spex_config",
      "\n# amendment: cli preferred_envs: [spex: :test]\n"
    )
  end

  defp append_if_missing(env, path, marker, snippet) do
    {:ok, content} = Environments.read_file(env, path)

    if String.contains?(content, marker) do
      :ok
    else
      Environments.write_file(env, path, content <> snippet)
    end
  end
end
