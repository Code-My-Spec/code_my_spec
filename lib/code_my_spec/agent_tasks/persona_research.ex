defmodule CodeMySpec.AgentTasks.PersonaResearch do
  @moduledoc """
  Run a persona research session with the PM.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/persona_research.spec.md`.
  """

  alias CodeMySpec.Requirements.{CheckerResult, PersonasChecker}

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec orchestrate(map()) :: String.t()
  def orchestrate(_node) do
    "Run a persona research session with the PM. Produce one persona on " <>
      "the project: DB record (create_persona) + summary.md + sources.md, " <>
      "linked to ≥1 story. Triangulate ≥3 sources per claim. Use when a " <>
      "story needs a linked persona for three_amigos to proceed. Manual " <>
      "validation."
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(_scope, _task) do
    {:ok, prompt()}
  end

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    scope |> PersonasChecker.complete?(nil) |> CheckerResult.to_evaluation()
  end

  # ============================================================================
  # Prompt assembly. Protocol detail lives in
  # priv/knowledge/persona_research/workflow.md plus the topic files
  # (pm_intake, primary_research, synthesis, etc.) — pointed at via the
  # playbook section rather than inlined here.
  # ============================================================================

  defp prompt do
    """
    # Persona Research

    You are running a **persona research session** with the Product Manager on
    this project. The deliverable is one persona on the project — a DB record
    plus two markdown artifacts — linked to at least one story.

    ## Prereqs

    Personas are **project-scoped**. `create_persona` and
    `link_persona_to_story` need the scope to carry an `active_project_id`.
    If `create_persona` returns `missing_active_project`, run `init_project`
    first to bind the working directory to a project, then retry.

    ## Reuse before research

    Call `list_personas` early in the intake to see if a prior session
    already covered this role. Reusing an existing persona via
    `link_persona_to_story` is often the right answer — don't research a
    duplicate.

    ## Read the playbook

    - `priv/knowledge/persona_research/workflow.md` — the five-step session
      (intake → challenge thin input → research → write artifacts → link),
      evidence bar (triangulate ≥3 sources), done signal, anti-patterns.
    - Topic files under `priv/knowledge/persona_research/`:
      `README.md`, `overview.md`, `pm_intake.md`, `primary_research.md`,
      `secondary_research.md`, `jtbd.md`, `synthesis.md`, `templates.md`,
      `pitfalls.md`. The workflow doc points at each.

    ## MCP tools you'll use

    - `list_personas` — check for reuse before researching.
    - `get_persona` — fetch full persona detail by slug or id.
    - `create_persona` (alias `add_persona`) — write the DB record.
    - `link_persona_to_story` — required for the done signal.
    - `evaluate_task` — manual validation trigger.

    ## Produced artifacts

    - DB persona record via `create_persona`.
    - `.code_my_spec/personas/<slug>/summary.md` — required H2 sections:
      Role, Goals, Pain Points, Context, Decision Drivers, Evidence.
      Optional H2: Jobs to Be Done, Quotes, Motivations, Behaviors,
      Anti-Patterns. Any other H2 fails validation.
    - `.code_my_spec/personas/<slug>/sources.md` — link list (URL, title,
      access date per entry).
    - Persona ↔ story link via `link_persona_to_story` (≥1 required).

    ## Manual validation

    The stop hook does NOT auto-evaluate. Stop freely between turns to
    let the PM respond — each stop is cheap, the task stays active. When
    you believe all artifacts exist and ≥1 story is linked, call
    `evaluate_task` to run `PersonasChecker.complete?`. Never fabricate
    artifacts to pass the checker. Thin in, nothing out.
    """
  end
end
