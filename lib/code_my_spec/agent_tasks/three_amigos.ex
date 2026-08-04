defmodule CodeMySpec.AgentTasks.ThreeAmigos do
  @moduledoc """
  Run an Example Mapping session on a single story.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/three_amigos.spec.md`.
  """

  alias CodeMySpec.Requirements.{BddRulesChecker, CheckerResult}
  alias CodeMySpec.Stories

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec dispatch(map()) :: String.t()
  def dispatch(_node) do
    "Run a Three Amigos / Example Mapping session on a story. Agent plays " <>
      "Business / Developer / QA while the PM holds intent; deliverable is " <>
      "rules + scenarios + questions persisted via MCP tools. Use when a " <>
      "story has a linked component but no rules/scenarios yet. Manual " <>
      "validation — the agent calls `evaluate_task` when readiness " <>
      "conditions are met."
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(scope, task) do
    case resolve_command_story(scope, task) do
      nil -> {:ok, no_story_prompt()}
      story -> {:ok, story_prompt(scope, story)}
    end
  end

  # The graph-dispatch route sets `entity_id` to the story id and
  # `requirement_name` to the requirement (e.g. "three_amigos_complete"),
  # so entity_id must win when both are present. The skill route
  # (`/codemyspec:product three-amigos <story_id>`) threads the story_id
  # through `requirement_name` instead per the topic-task convention.
  defp resolve_command_story(scope, %{entity_id: entity_id}) when is_binary(entity_id) do
    fetch_story(scope, entity_id)
  end

  defp resolve_command_story(scope, %{requirement_name: requirement}) when is_binary(requirement) do
    fetch_story(scope, requirement)
  end

  defp resolve_command_story(_scope, _task), do: nil

  @spec evaluate(term(), map()) ::
          {:ok, :valid} | {:ok, :valid, String.t()} | {:ok, :invalid, String.t()}
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
  # Prompt assembly. Protocol detail lives in the framework knowledge library
  # at `three_amigos/workflow.md` (read via the `read_knowledge` MCP tool) —
  # pointed at via the playbook section rather than inlined here.
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

  defp story_prompt(scope, story) do
    base_url = CodeMySpec.PublicUrl.local_base()

    # `/app`-prefixed and addressed by project id. The old shape —
    # `/projects/<name-slug>/...` — 404s: the local routes moved under `/app`
    # and every project surface takes a UUID now. Nothing caught it because
    # this is a string assembled into a prompt, not a `~p` the router verifies
    # and not a link in a view.
    session_url =
      "#{base_url}/app/projects/#{project_id(scope)}/stories/#{story.id}/three-amigos"
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

  defp project_id(%{active_project: %{id: id}}), do: id
  defp project_id(%{active_project_id: id}) when not is_nil(id), do: id

  defp playbook_section do
    """
    ## Read the playbook

    Read `three_amigos/workflow.md` via the `read_knowledge` MCP tool —
    protocol ordering (persona → rules → scenarios → questions), MCP tool
    usage per phase, done-signal conditions, anti-patterns to avoid.
    """
  end
end
