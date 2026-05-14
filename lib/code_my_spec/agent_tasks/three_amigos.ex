defmodule CodeMySpec.AgentTasks.ThreeAmigos do
  @moduledoc """
  Run an Example Mapping session on a single story.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/three_amigos.spec.md`.
  """

  alias CodeMySpec.Requirements.{BddRulesChecker, CheckerResult}
  alias CodeMySpec.Stories

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec orchestrate(map()) :: String.t()
  def orchestrate(_node) do
    "Three Amigos / Example Mapping session — produce rules + scenarios + " <>
      "questions on a story via MCP tools. Use when a story has a linked " <>
      "component but no rules yet. Manual validation."
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(scope, task) do
    case resolve_command_story(scope, task) do
      nil -> {:ok, no_story_prompt()}
      story -> {:ok, story_prompt(story)}
    end
  end

  # The skill route (`/codemyspec:product three-amigos <story_id>`) threads
  # the story_id through `requirement_name` per the topic-task convention.
  # The graph-dispatch route uses `entity_id`. Either lands us at the right
  # Story.
  defp resolve_command_story(scope, %{requirement_name: requirement}) when is_binary(requirement) do
    fetch_story(scope, requirement)
  end

  defp resolve_command_story(scope, %{entity_id: entity_id}) when is_binary(entity_id) do
    fetch_story(scope, entity_id)
  end

  defp resolve_command_story(_scope, _task), do: nil

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, task) do
    story = resolve_story(scope, task)
    scope |> BddRulesChecker.complete?(story) |> CheckerResult.to_evaluation()
  end

  defp resolve_story(scope, %{entity_type: :story, entity_id: entity_id}) when is_binary(entity_id) do
    fetch_story(scope, entity_id)
  end

  defp resolve_story(scope, %{entity_type: "story", entity_id: entity_id}) when is_binary(entity_id) do
    fetch_story(scope, entity_id)
  end

  defp resolve_story(scope, %{entity_id: entity_id}) when is_binary(entity_id) do
    fetch_story(scope, entity_id)
  end

  defp resolve_story(_scope, _task), do: nil

  defp fetch_story(scope, entity_id) do
    case Integer.parse(entity_id) do
      {id, ""} -> Stories.get_story(scope, id)
      _ -> nil
    end
  end

  # ============================================================================
  # Prompt assembly. Protocol detail lives in
  # priv/knowledge/three_amigos/workflow.md — pointed at via the playbook
  # section rather than inlined here.
  # ============================================================================

  defp no_story_prompt do
    """
    # Three Amigos

    You are running a **Three Amigos / Example Mapping** session with the
    Product Manager. You play all three amigos — Business, Developer, QA —
    while the PM holds product intent.

    > **Story not provided.** This task should always be scoped to a single
    > story. Ask the PM which story the session is for, then call MCP tools
    > with that `story_id`.

    #{playbook_section()}
    """
  end

  defp story_prompt(story) do
    base_url = Application.get_env(:code_my_spec, :base_url, "http://localhost:4000")
    session_url = "#{base_url}/app/stories/#{story.id}/three-amigos"
    quoted_description = String.replace(story.description || "(no description)", "\n", "\n> ")

    """
    # Three Amigos — Story #{story.id}: #{story.title}

    You are running a **Three Amigos / Example Mapping** session with the
    Product Manager on **story_id `#{story.id}`** — *#{story.title}*.

    Story description:

    > #{quoted_description}

    You play all three amigos — **Business** (rules and outcomes),
    **Developer** (constraints and dependencies), **QA** (failure modes
    and edge cases) — while the PM holds product intent.

    Pass `story_id: #{story.id}` to every MCP tool call (`add_persona` is
    project-scoped and resolves the project from your working directory's
    scope — it doesn't need a story_id; everything else does).

    **Session URL** (share with the PM so they can watch cards appear in
    real time): #{session_url}

    The deliverable is a populated set of Rule + Criterion (scenario) +
    Question records on the story, persisted via MCP tools. No flat files.
    No Gherkin written to disk.

    #{playbook_section()}

    ## Done signal — manual validation

    The stop hook does NOT auto-evaluate this requirement. When you believe
    the readiness conditions in the playbook are met, call `evaluate_task`
    to run the checker. On pass the task completes and the graph advances;
    on fail you get feedback and continue.
    """
  end

  defp playbook_section do
    """
    ## MCP tools you'll call (per protocol phase)

    - **Persona** — `list_personas`, `add_persona`, `link_persona_to_story`.
    - **Rules** — `add_rule` (one rule per call).
    - **Scenarios** — `add_scenario` (one per call, `kind: happy_path` or
      `failure_path`).
    - **Questions** — `add_question` (parks unresolved questions; don't
      let them derail).

    ## Read the playbook

    `priv/knowledge/three_amigos/workflow.md` — protocol ordering (persona
    → rules → scenarios → questions), MCP tool usage per phase, done-signal
    conditions, anti-patterns. The knowledge MCP also serves the framework
    BDD docs at `priv/knowledge/bdd/spex/` if you need the broader context.

    ## Idempotent reruns — check what's already on the story

    If this is a continuation of a prior session, call these BEFORE
    starting fresh so you don't duplicate work:

    - `list_rules` (story_id) — rules already persisted.
    - `list_questions` (story_id) — questions already parked.
    - `get_story_gherkin` (story_id) — full Gherkin view (rules +
      scenarios) in one call.
    """
  end
end
