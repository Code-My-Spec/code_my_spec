defmodule CodeMySpec.AgentTasks.TriageIssues do
  @moduledoc """
  Agent task for triaging incoming QA issues.

  Reviews incoming issues from the database and decides dispositions
  (accept, dismiss, merge), each executed through the `accept_issue` /
  `dismiss_issue` MCP tools.

  Issues are **not** projected to files. There was once a projector writing
  `.code_my_spec/issues/{incoming,accepted,dismissed}/` for the agent to edit a
  `## Status` field in, and this moduledoc went on describing that flow long
  after the tools replaced it — `evaluate/2` was documented as reconciling file
  edits back to the DB when it has only ever counted rows. The projector and
  those directories are gone; `.code_my_spec/issues/` now holds hand-written
  braindumps only.

  Two scopes, matching the two requirements it satisfies:

    * **project** (`issues_triaged`) — `Issues.list_triageable/2`: incoming
      issues at the threshold, plus every incoming issue on a story at any
      severity. The threshold is the project's `fix_issues_min_severity`,
      overridable via `task.state["topic"]`.
    * **story** (`story_issues_triaged`) — every incoming issue on that story,
      any severity. An untriaged finding on a story holds its QA (255f1dcd).

  Both read the set the checker gates on, so the task cannot evaluate green
  while the requirement it was offered for is still unsatisfied.
  """

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Stories

  @doc """
  Build a triage prompt declaring what to triage. Returns `{:ok, prompt_text}`.

  The prompt does NOT enumerate issues — the agent discovers them via the
  `list_issues` MCP tool. This keeps the prompt stable regardless of how
  many issues exist and forces the agent to use the canonical tool surface.
  """
  def command(scope, task) do
    target = target(scope, task)
    {:ok, build_prompt(target, remaining(scope, target))}
  end

  @doc """
  Check that nothing the task covers is still incoming.

  Returns `{:ok, :valid}` or `{:ok, :invalid, feedback}`.
  """
  def evaluate(scope, task) do
    target = target(scope, task)

    case remaining(scope, target) do
      [] ->
        {:ok, :valid}

      issues ->
        names = Enum.map_join(issues, "\n", &"- `#{&1.title}` [#{&1.severity}]")

        {:ok, :invalid,
         "#{length(issues)} untriaged issue(s) remain #{describe(target)}:\n\n#{names}\n\nUse the `accept_issue` or `dismiss_issue` MCP tools for each remaining issue."}
    end
  end

  def dispatch(_node) do
    "Triage incoming QA issues: every issue on a story at any severity, and " <>
      "the rest at the configured minimum severity (default `:medium`). For " <>
      "each issue: read via `get_issue`, decide accept / dismiss / merge, and " <>
      "execute via `accept_issue` / `dismiss_issue` MCP tools."
  end

  # ============================================================================
  # Scope
  # ============================================================================

  defp target(scope, %{story_id: story_id}) when not is_nil(story_id) do
    id = parse_story_id(story_id)
    {:story, id, story_number(scope, id)}
  end

  defp target(scope, task), do: {:project, get_min_severity(scope, task)}

  defp remaining(scope, {:story, story_id, _number}),
    do: Issues.list_filtered(scope, %{status: :incoming, story_id: story_id})

  defp remaining(scope, {:project, min_severity}),
    do: Issues.list_triageable(scope, min_severity)

  defp describe({:story, _id, number}), do: "on story #{number}, at any severity"
  defp describe({:project, min_severity}), do: "at #{min_severity}+ severity or on a story"

  defp parse_story_id(id) when is_integer(id), do: id

  defp parse_story_id(id) do
    case Integer.parse(to_string(id)) do
      {int, _} -> int
      :error -> id
    end
  end

  defp story_number(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> story_id
      story -> story.number
    end
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt(target, []) do
    """
    # Triage Issues

    No incoming issues #{describe(target)}. Nothing to triage.
    """
  end

  defp build_prompt({:story, _id, number} = target, _issues) do
    """
    # Triage Issues — story #{number}

    You are triaging every incoming issue #{describe(target)}. An untriaged
    issue holds this story's QA whatever its severity, so a low needs a
    decision too.

    #{tools_and_goal("`status: \"incoming\"` and `story_number: #{number}`")}

    Accepting keeps the issue on this story. Only accepted issues at the
    project's `fix_issues_min_severity` must be fixed before QA re-tests; an
    accepted low stays tracked without blocking.

    Stop the session when every issue on the story has been triaged.
    """
  end

  defp build_prompt({:project, _} = target, _issues) do
    """
    # Triage Issues

    You are triaging incoming issues #{describe(target)}. Issues below the
    threshold with no story are left for later.

    #{tools_and_goal("`status: \"incoming\"` and the appropriate `severity` filter")}

    ## Accepting puts it on the graph — so link it

    `story_issues_resolved` is per-story. An unlinked issue gates nothing and
    reaches no agent.

    Ask which story's promise the defect breaks, and pass `story_number` **on the
    `accept_issue` call** — `accepted → accepted` is rejected, so a missed link
    needs repairing with `update_issue` afterwards. Story numbers are listed by
    `list_story_titles`.

    Genuinely project-level issues (tooling, harness) stay unlinked — but say so,
    or it reads as an oversight.

    Stop the session when all issues have been triaged.
    """
  end

  defp tools_and_goal(list_filter) do
    """
    ## Tools

    - `list_issues` — list issues (pass `status: "incoming"` to filter)
    - `get_issue` — read full issue details (pass the issue `id`)
    - `accept_issue` — accept a real issue (pass the issue `id`)
    - `dismiss_issue` — dismiss with a reason (pass `id` and `reason`)

    ## Goal

    1. **Discover issues** using `list_issues` with #{list_filter}
    2. **Read each issue** using `get_issue` with the issue `id`
    3. **Identify duplicates** — issues describing the same underlying problem
    4. **Decide a disposition** for each issue:
       - **Accept** — real issue, call `accept_issue` with the issue `id` **and a `story_number`**
       - **Dismiss** — not a real bug (test artifact, expected behavior, duplicate), call `dismiss_issue` with the issue `id` and `reason`
       - **Merge** — accept the best issue, dismiss the others with a reason noting the duplicate
    5. **Execute** each disposition using the tools above\
    """
  end

  # ============================================================================
  # Severity Helpers
  # ============================================================================

  defp get_min_severity(_scope, %{state: %{"topic" => topic}})
       when is_binary(topic) and topic != "" do
    parse_severity(topic)
  end

  defp get_min_severity(scope, _task), do: Configurations.fix_issues_min_severity(scope)

  defp parse_severity(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "critical" -> :critical
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      "info" -> :info
      _ -> :medium
    end
  end
end
