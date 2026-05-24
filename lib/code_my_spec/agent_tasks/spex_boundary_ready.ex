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

  def dispatch(_node) do
    "Install BDD spec boundary protections: framework Credo checks " <>
      "(function-level denies only), a project-local deny check that fills " <>
      "in whole-module denies (stdlib + app contexts), a curated " <>
      "`<App>Spex.Fixtures` bridge as its own top-level Boundary, and a " <>
      "project BDD spec plan. Use when the architecture proposal exists " <>
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
  # Prompt assembly. Static procedural detail lives in the framework knowledge
  # library at `spex_boundary_ready/workflow.md` (read via the `read_knowledge`
  # MCP tool) — pointed at via the playbook section rather than inlined here.
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
    are on disk. Quality of the local Credo check's deny list, the
    fixtures-bridge re-export list, and the project BDD plan content lives
    in the playbook and in this turn's planning. Do the thinking now — next
    turn won't see it.

    Key design notes you should know up front:

    - The framework `spex_denied_calls.ex` ships with **empty whole-module
      lists**. Stdlib bypasses (`File`, `Port`, `:file`) live in the
      project-local check — not the framework one.
    - The fixtures bridge is **its own top-level Boundary**, not a member
      of the spec boundary. That's how it can dep on `<App>` without
      leaking those deps into specs.\
    """
  end

  defp proposal_section(proposal_path, true) do
    """
    ## Architecture proposal

    Read `#{proposal_path}` — every `<App>` context listed there that isn't
    already a dep of the spec boundary belongs on the project-local deny
    list (plus `<App>.Repo`).\
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

    Read these via the `read_knowledge` MCP tool:

    - `spex_boundary_ready/workflow.md` — full 5-step install procedure:
      framework Credo checks, project-local whole-module deny check,
      fixtures bridge (as its own top-level Boundary), project BDD spec
      plan, stop.
    - `bdd/spex/philosophy.md` — why specs are sealed.
    - `bdd/spex/boundaries.md` — what a spec may call and why the fixtures
      bridge is a separate top-level Boundary.
    - `bdd/spex/writing_a_spex.md` — DSL and setup template.

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
    | Local check file | `#{local_dir}/#{app_name}_spex_denies.ex` |
    | Local check module | `#{app_module}.Check.Warning.#{app_module}SpexDenies` |
    | Local check id | `"#{check_id_prefix}0001"` |

    ## Standard whole-module denies to bake into the local check

    Universal stdlib bypasses — copy these as the baseline:

    - `File`, `:file` — real-disk reads bypass the in-memory environment.
    - `Port` — talks to external programs; use cassettes for CLI pipelines.

    Project denies — add these after reading
    `.code_my_spec/architecture/proposal.md`:

    - `#{app_module}.Repo` — direct DB reads bypass the public surface.
    - Every `#{app_module}.<Context>` listed in the proposal that the spec
      boundary (`test/spex/#{app_name}_spex.ex`) does NOT already dep on.\
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
