defmodule CodeMySpec.Requirements.SpexBoundaryChecker do
  @moduledoc """
  Delegate checker for the `spex_boundary_ready` requirement on
  `project_graph`.

  Verifies that the BDD-spec boundary protections are physically present
  in the project. Existence is the only assertion — content quality
  (project-specific denies in `local/`, fixture function selection)
  lives in the agent prompt, not in this checker.

  Required artifacts:

    * `.code_my_spec/credo_checks/framework/spex_denied_calls.ex` — the
      framework's function-level denies (System.cmd / Code.eval /
      Kernel.apply / :os.cmd) inside `_spex.exs` files. Whole-module
      denies live in the project-local check.
    * `.code_my_spec/credo_checks/framework/no_direct_send_in_spex.ex` —
      denies direct `send/2` from a spec, forcing PubSub interactions to
      go through the real Phoenix surface.
    * At least one `.ex` file under `.code_my_spec/credo_checks/local/` —
      the project-local check filling in whole-module denies (stdlib
      bypasses + internal app contexts).
    * `test/support/fixtures/<app>_spex_fixtures.ex` — the curated bridge
      module that's the only legal door from a spec into in-app state.

  Returns `{boolean(), map()}` per the checker contract.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.Users.Scope

  @framework_check_files ["spex_denied_calls.ex", "no_direct_send_in_spex.ex"]

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{environment: env}, _entity) when not is_nil(env) do
    gaps =
      []
      |> add_credo_check_gaps(env)
      |> add_local_credo_check_gap(env)
      |> add_fixtures_bridge_gap(env)
      |> add_project_bdd_plan_gap(env)

    case gaps do
      [] -> {true, %{status: "Spex boundary protections installed"}}
      gaps -> {false, %{reason: format_gaps(gaps)}}
    end
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "Environment is not available — cannot verify spex boundary files."}}
  end

  defp add_credo_check_gaps(gaps, env) do
    framework_dir = Paths.credo_checks_framework_dir()

    missing =
      Enum.reject(@framework_check_files, fn file ->
        Environments.file_exists?(env, Path.join(framework_dir, file)) == true
      end)

    Enum.map(missing, fn file ->
      "`#{Path.join(framework_dir, file)}` is missing — call `install_credo_checks` to copy framework checks into the project."
    end) ++ gaps
  end

  # Looks for at least one .ex file under `.code_my_spec/credo_checks/local/`.
  # The local check carries the project's whole-module deny list (stdlib
  # bypasses + internal app contexts); without it the framework template
  # alone has no whole-module denies wired up.
  defp add_local_credo_check_gap(gaps, env) do
    local_dir = Paths.credo_checks_local_dir()

    case Environments.list_directory(env, local_dir) do
      {:ok, entries} ->
        if Enum.any?(entries, &String.ends_with?(&1, ".ex")) do
          gaps
        else
          [
            "`#{local_dir}/` exists but contains no project-local Credo check (`*.ex`) — write `<app>_spex_denies.ex` filling in @denied_whole_modules with stdlib bypasses (File, Port, :file) plus internal app contexts from the architecture proposal."
            | gaps
          ]
        end

      _ ->
        [
          "`#{local_dir}/` is missing — write the project-local Credo check that fills in the whole-module deny list."
          | gaps
        ]
    end
  end

  defp add_fixtures_bridge_gap(gaps, env) do
    case Helpers.extract_app_name(env) do
      nil ->
        ["Could not determine app name from `mix.exs` — cannot verify fixtures bridge." | gaps]

      app ->
        path = Path.join(["test", "support", "fixtures", "#{app}_spex_fixtures.ex"])

        if Environments.file_exists?(env, path) == true do
          gaps
        else
          [
            "`#{path}` is missing — write the curated fixtures bridge module that re-exports state setup helpers from `<App>Test` for use in BDD specs."
            | gaps
          ]
        end
    end
  end

  # Looks for at least one .md file in `.code_my_spec/knowledge/bdd/spex/`.
  # Filename is the agent's choice — `index.md` is the convention but not
  # required by the checker. Existence-only, like the other gaps.
  defp add_project_bdd_plan_gap(gaps, env) do
    plan_dir = Path.join([Paths.knowledge_dir(), "bdd", "spex"])

    case Environments.list_directory(env, plan_dir) do
      {:ok, entries} ->
        if Enum.any?(entries, &String.ends_with?(&1, ".md")) do
          gaps
        else
          [
            "`#{plan_dir}/` exists but contains no project BDD spec plan (`*.md`) — write a project-tailored doc covering this project's public surfaces, fixture inventory, and observable patterns."
            | gaps
          ]
        end

      _ ->
        [
          "`#{plan_dir}/` is missing — write a project-specific BDD spec plan that complements the generic framework BDD docs at `.code_my_spec/framework/bdd/spex/`."
          | gaps
        ]
    end
  end

  defp format_gaps(gaps) do
    bullets = Enum.map_join(gaps, "\n", &"- #{&1}")
    "Spex boundary not ready:\n\n#{bullets}"
  end
end
