defmodule CodeMySpec.AgentTasks.ThreeAmigos do
  @moduledoc """
  Agent task for running a Three Amigos / Example Mapping session on a
  single story.

  `command/2` returns a prompt that orients the agent on the protocol,
  enumerates the available MCP tools (`add_rule`, `add_scenario`,
  `add_question`, `add_persona`, `link_persona_to_story`), and points at
  the knowledge MCP for protocol guidance. The agent plays all three
  amigos (Business / Developer / QA), the PM holds intent, and the
  deliverable is a populated set of Rule + Criterion + Question records
  on the story.

  `evaluate/2` delegates to `BddRulesChecker.complete?/2`, which enforces
  the readiness gate (≥1 persona linked, ≥1 rule, ≥1 scenario for the
  initial pass; full coverage rules land with the Questions context and
  Criterion `kind` enrichment).

  Mirrors the persona research task pattern.
  """

  alias CodeMySpec.Requirements.{BddRulesChecker, CheckerResult}
  alias CodeMySpec.Stories

  @spec analyzers() :: [atom()]
  def analyzers, do: []

  @spec orchestrate(map()) :: String.t()
  def orchestrate(node) do
    "Run a Three Amigos session — interview the PM, link or create personas, " <>
      "produce rules and scenarios. " <>
      "Call `start_task` with requirement_name `#{node.name}`, " <>
      "entity_type `#{node.entity_type}`, entity_id `#{node.entity_id}`."
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(scope, task) do
    case resolve_command_story(scope, task) do
      nil -> {:ok, prompt(nil)}
      story -> {:ok, prompt(story)}
    end
  end

  # The skill route (`/codemyspec:product three-amigos <story_id>`)
  # threads the story_id through `requirement_name` per the topic-task
  # convention. The graph-dispatch route uses `entity_id`. Either lands
  # us at the right Story.
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

  defp prompt(nil) do
    """
    # Three Amigos

    You are running a **Three Amigos / Example Mapping** session with the
    Product Manager. You play all three amigos —
    **Business** (rules and outcomes), **Developer** (constraints and
    dependencies), **QA** (failure modes and edge cases) — while the PM
    holds product intent.

    > **Story not provided.** This task should always be scoped to a
    > single story. If you got here without one, ask the PM which story
    > the session is for, then call MCP tools with that `story_id`.
    """ <> protocol_body()
  end

  defp prompt(story) do
    base_url = Application.get_env(:code_my_spec, :base_url, "http://localhost:4000")
    session_url = "#{base_url}/app/stories/#{story.id}/three-amigos"

    """
    # Three Amigos — Story #{story.id}: #{story.title}

    You are running a **Three Amigos / Example Mapping** session with the
    Product Manager on **story_id `#{story.id}`** — *#{story.title}*.

    Story description:

    > #{String.replace(story.description || "(no description)", "\n", "\n> ")}

    You play all three amigos — **Business** (rules and outcomes),
    **Developer** (constraints and dependencies), **QA** (failure modes
    and edge cases) — while the PM holds product intent.

    Pass `story_id: #{story.id}` to every MCP tool call below
    (`add_persona` is account-scoped and doesn't need it; everything
    else does).

    **Session URL** (share this with the PM so they can watch cards
    appear in real time): #{session_url}
    """ <> protocol_body()
  end

  defp protocol_body do
    """



    The deliverable is a populated set of Rule + Criterion (scenario) +
    Question records on the story, persisted via dedicated MCP tools.
    No flat files. No Gherkin written to disk.

    ## Read the playbook first

    Before writing anything, query the knowledge MCP server for protocol
    guidance:

    - `semantic_search` with a query about the Three Amigos protocol,
      readiness rules, and scenario quality bar.

    The knowledge corpus contains the workshop facilitation script,
    rule/scenario quality criteria, and the readiness gate definition.

    ## Protocol ordering

    Persona linkage → Rules → Scenarios. Do not skip ahead.

    1. **Persona linkage.** Use `list_personas` to see what already
       exists in the account library. If a suitable persona exists,
       call `link_persona_to_story`. If not, call `add_persona` (alias
       for `create_persona`) to add a lightweight record (identity +
       metadata only — no research artifacts), then link it. Full
       persona research happens later as a separate `personas_complete`
       requirement on the next graph pass.

    2. **Rules (blue cards).** For each governing constraint or
       business rule, call `add_rule` with the story_id and the
       rule statement in business terms.

    3. **Scenarios (green cards).** For each rule, generate at least
       one happy-path scenario and one failure-path scenario. Call
       `add_scenario` with story_id, the rule, a title, kind
       (`happy_path` or `failure_path`), and the Given/When/Then
       body in plain Gherkin.

    4. **Questions (red cards).** Park unresolved questions with
       `add_question`. Don't let them derail the conversation.

    ## Done signal

    The `three_amigos_complete` requirement is satisfied when:

    - ≥1 persona is linked to the story
    - ≥1 Rule exists on the story
    - ≥1 Criterion (scenario) exists on the story

    (The full readiness gate — rules < 10, scenarios > questions,
    every rule has happy + failure — is enforced in a richer pass
    once the Questions context and Criterion `kind` enrichment land.)

    ## This is a manual-validation task

    The stop hook does NOT auto-evaluate this requirement. You own the
    completion signal:

    - Freely stop between turns to let the PM respond.
    - When you believe the readiness conditions are met, call
      `evaluate_task` to run the checker. On pass, the task completes
      and the graph advances.
    - If the PM directs you to abandon the session (refuses to
      provide intent, walks away), the task remains open for the
      next run.
    """
  end
end
