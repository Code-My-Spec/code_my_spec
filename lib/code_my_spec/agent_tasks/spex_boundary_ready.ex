defmodule CodeMySpec.AgentTasks.SpexBoundaryReady do
  @moduledoc """
  Install the project-local infrastructure that protects the BDD spec boundary.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/spex_boundary_ready.spec.md`.
  """

  alias CodeMySpec.AgentTasks.Setup.Helpers
  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.Requirements.{CheckerResult, SpexBoundaryChecker}

  # ============================================================================
  # orchestrate — relevance signal for the requirement graph
  # ============================================================================

  def orchestrate(_node) do
    "Install BDD spec boundary protections: framework Credo checks, a " <>
      "project-local deny check, a curated `<App>Spex.Fixtures` bridge, and " <>
      "a project BDD spec plan. Use when the architecture proposal exists " <>
      "and the project is about to start writing BDD specs but the boundary " <>
      "infrastructure isn't on disk yet."
  end

  # ============================================================================
  # Command
  # ============================================================================

  @spec command(CodeMySpec.Users.Scope.t(), map()) :: {:ok, String.t()}
  def command(%{environment: nil}, _task) do
    {:ok,
     "# Spex Boundary Ready\n\nProject environment is not available yet — finish project setup so the working directory is bound, then re-open this requirement."}
  end

  def command(scope, _task) do
    env = scope.environment
    app_name = Helpers.extract_app_name(env) || "your_app"
    app_module = camelize(app_name)
    proposal_path = Path.join(Paths.architecture_dir(), "proposal.md")
    proposal_present? = Environments.file_exists?(env, proposal_path) == true

    {:ok, build_prompt(app_name, app_module, proposal_path, proposal_present?)}
  end

  # ============================================================================
  # Evaluate — delegates to SpexBoundaryChecker (existence-only)
  # ============================================================================

  @spec evaluate(CodeMySpec.Users.Scope.t(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    scope |> SpexBoundaryChecker.complete?(nil) |> CheckerResult.to_evaluation()
  end

  # ============================================================================
  # Prompt assembly. Static procedural detail lives in
  # priv/knowledge/spex_boundary_ready/workflow.md — pointed at via the
  # playbook section rather than inlined here.
  # ============================================================================

  defp build_prompt(app_name, app_module, proposal_path, proposal_present?) do
    [
      header_section(),
      proposal_section(proposal_path, proposal_present?),
      playbook_section(),
      project_specifics_section(app_name, app_module),
      done_signal_section(app_name)
    ]
    |> Enum.join("\n\n")
  end

  defp header_section do
    """
    # Spex Boundary Ready

    Install the four pieces of project-local infrastructure that protect the
    BDD spec boundary, so subsequent `write_bdd_specs` and `fix_bdd_specs`
    work runs against a sealed surface.

    Validation is existence-only — the checker only verifies the artifacts
    are on disk. Quality of the local Credo check, the fixtures-bridge
    re-export list, and the project BDD plan content lives in the playbook
    and in this turn's planning. Do the thinking now — next turn won't see it.\
    """
  end

  defp proposal_section(proposal_path, true) do
    """
    ## Architecture proposal

    Read `#{proposal_path}` — it's the source for the list of internal
    namespaces your project-local Credo check will deny.\
    """
  end

  defp proposal_section(proposal_path, false) do
    """
    ## Architecture proposal — MISSING

    `#{proposal_path}` doesn't exist. **Stop and resolve
    `architecture_designed` first.** Without the proposal, the project-local
    Credo check has nothing to derive its deny list from.\
    """
  end

  defp playbook_section do
    """
    ## Read the playbook

    - `priv/knowledge/spex_boundary_ready/workflow.md` — full 5-step install
      procedure: framework Credo checks, project-local deny check, fixtures
      bridge, project BDD spec plan, stop.
    - `priv/knowledge/bdd/spex/philosophy.md` — why specs are sealed.
    - `priv/knowledge/bdd/spex/boundaries.md` — what a spec may call.
    - `priv/knowledge/bdd/spex/writing_a_spex.md` — DSL and setup template.

    The playbook references concrete paths under
    `.code_my_spec/credo_checks/`, `test/support/fixtures/`, and
    `.code_my_spec/knowledge/bdd/spex/` — those are the produced-artifact
    locations the validator checks.\
    """
  end

  # Project-tailored substitutions — the playbook uses `<App>` placeholders;
  # this section names the real module + a starter Credo check id so the
  # agent doesn't have to derive them again.
  defp project_specifics_section(app_name, app_module) do
    fixtures_path = "test/support/fixtures/#{app_name}_spex_fixtures.ex"
    check_id_prefix = check_id_prefix(app_name)
    framework_dir = Paths.credo_checks_framework_dir()
    local_dir = Paths.credo_checks_local_dir()

    """
    ## This project — substitutions for the playbook

    | Placeholder | This project |
    |---|---|
    | `<App>` | `#{app_module}` |
    | `<app>` | `#{app_name}` |
    | Fixtures bridge path | `#{fixtures_path}` |
    | Framework Credo checks dir | `#{framework_dir}` |
    | Project-local Credo checks dir | `#{local_dir}` |
    | Starter Credo check id | `"#{check_id_prefix}0001"` |\
    """
  end

  defp done_signal_section(app_name) do
    fixtures_path = "test/support/fixtures/#{app_name}_spex_fixtures.ex"

    """
    ## Done signal

    Stop the session once all four artifacts exist:

    1. Framework Credo checks at `#{Paths.credo_checks_framework_dir()}/`.
    2. At least one project-local check at `#{Paths.credo_checks_local_dir()}/`.
    3. The fixtures bridge at `#{fixtures_path}`.
    4. At least one `.md` at `.code_my_spec/knowledge/bdd/spex/`.

    Missing pieces produce specific feedback on the next run.\
    """
  end

  defp camelize(name) do
    name |> String.split("_") |> Enum.map_join("", &String.capitalize/1)
  end

  defp check_id_prefix(app_name) do
    app_name
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
    |> String.slice(0, 6)
  end
end
