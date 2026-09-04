defmodule CodeMySpec.AgentTasks.PersonaResearch do
  @moduledoc """
  Run a persona research session with the PM.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/persona_research.spec.md`.
  """

  alias CodeMySpec.Requirements.{CheckerResult, PersonasChecker}
  alias CodeMySpec.Users.Scope

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec dispatch(map()) :: String.t()
  def dispatch(_node) do
    "Run a persona research session with the PM. Produce one persona on " <>
      "the project: DB record (create_persona) + summary.md + sources.md, " <>
      "linked to ≥1 story. Triangulate ≥3 sources per claim. Use when a " <>
      "story needs a linked persona for three_amigos to proceed. Manual " <>
      "validation."
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(scope, _task) do
    {:ok, prompt() <> outstanding_section(scope)}
  end

  # Name what is actually missing, rather than making the agent rediscover it.
  #
  # The prompt used to say "produce one persona" and stop there, so an agent
  # arriving without conversation history had to call `list_personas`, guess
  # which one was unresearched, and hope. `PersonasChecker` already knows —
  # it is the thing about to judge this task — so ask it and print its answer.
  # Naming the checker's own gaps, rather than inferring from `type: proto`,
  # also means the prompt cannot drift from the bar it is graded against.
  defp outstanding_section(%Scope{} = scope) do
    case PersonasChecker.complete?(scope, nil) do
      {false, %{reason: reason}} -> "\n## Outstanding\n\n#{reason}\n"
      _ -> ""
    end
  end

  defp outstanding_section(_scope), do: ""

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, _task) do
    scope |> PersonasChecker.complete?(nil) |> CheckerResult.to_evaluation()
  end

  # ============================================================================
  # Prompt assembly. Protocol detail lives in the framework knowledge library
  # at `persona_research/workflow.md` plus the topic files (pm_intake,
  # primary_research, synthesis, etc.) — read via the `read_knowledge` MCP
  # tool, pointed at via the playbook section rather than inlined here.
  # ============================================================================

  defp prompt do
    """
    # Persona Research

    You are running a **persona research session** with the Product Manager on
    this project. The deliverable is one persona on the project — a DB record
    plus two markdown artifacts.

    ## Prereqs

    Personas are **project-scoped**. `create_persona` needs the scope to
    carry an `active_project_id`.
    If `create_persona` returns `missing_active_project`, run `init_project`
    first to bind the working directory to a project, then retry.

    ## Reuse before research

    Call `list_personas` early in the intake to see if a prior session
    already covered this role. Reusing an existing persona is often the
    right answer — don't research a duplicate.

    ## Read the playbook

    Read these via the `read_knowledge` MCP tool:

    - `persona_research/workflow.md` — the five-step session (intake →
      challenge thin input → research → write artifacts → link), evidence
      bar (triangulate ≥3 sources), done signal, anti-patterns. Read this
      first; it routes to the right methodology guide.
    - **If the persona's actor is an LLM agent class** (e.g. `Per-Story QA
      Agent`, `Code Writer Agent`) → switch to
      `persona_research/agent_personas.md`. The artifact contract is
      identical (summary.md + sources.md, same H2 sections), but sources
      are agent definitions / MCP spec / log behavior / self-reflection —
      no intake interview, no JTBD, no human secondary research.
    - Topic files for the **human** path under `persona_research/`:
      `README.md`, `overview.md`, `pm_intake.md`, `primary_research.md`,
      `secondary_research.md`, `jtbd.md`, `synthesis.md`, `templates.md`,
      `pitfalls.md`. The workflow doc points at each; browse the directory
      with `list_knowledge` if needed.

    ## MCP tools you'll use

    - `list_personas` — check for reuse before researching.
    - `get_persona` — fetch full persona detail by slug or id.
    - `create_persona` — write the DB record.
    - `evaluate_task` — manual validation trigger.

    ## Produced artifacts

    - DB persona record via `create_persona`.
    - `.code_my_spec/personas/<slug>/summary.md` — required H2 sections:
      Role, Goals, Pain Points, Context, Decision Drivers, Evidence.
      Optional H2: Jobs to Be Done, Quotes, Motivations, Behaviors,
      Anti-Patterns. Any other H2 fails validation.
    - `.code_my_spec/personas/<slug>/sources.md` — link list (URL, title,
      access date per entry).

    ## Manual validation

    The stop hook does NOT auto-evaluate. Stop freely between turns to
    let the PM respond — each stop is cheap, the task stays active. When
    you believe all artifacts exist, call `evaluate_task` to run
    `PersonasChecker.complete?`. Never fabricate
    artifacts to pass the checker. Thin in, nothing out.
    """
  end
end
