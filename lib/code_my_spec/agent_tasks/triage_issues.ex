defmodule CodeMySpec.AgentTasks.TriageIssues do
  @moduledoc """
  Agent task for triaging incoming QA issues.

  Reviews all incoming issues from the database, decides dispositions
  (accept, dismiss, merge), and edits the `## Status` field in projected
  issue files from `incoming` to `accepted` or `dismissed`.

  Accepts an optional minimum severity via `task.state["topic"]` (default: :medium).
  Only issues at or above the specified severity are included in the triage.

  Two main functions:
  - `command/2` — Pulls server-side incoming issues into the local DB, then
    declares the threshold; agent discovers issues via `list_issues`
  - `evaluate/2` — Reconciles status field changes to DB, checks that no incoming issues remain
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue

  @doc """
  Pull server-side incoming issues into the local DB, then build a triage
  prompt declaring the severity threshold.

  The remote pull is synchronous and fails loudly: if the server is
  unreachable, `command/2` returns `{:error, {:server_unreachable, message}}`
  so StartTask surfaces the error in the response (no triage prompt is
  built).

  The prompt does NOT enumerate issues — the agent discovers them via the
  `list_issues` MCP tool. This keeps the prompt stable regardless of how
  many issues exist and forces the agent to use the canonical tool surface.

  Returns `{:ok, prompt_text}`.
  """
  def command(scope, task) do
    min_severity = get_min_severity(task)
    issues = list_incoming_at_severity(scope, min_severity)

    prompt = build_prompt(issues, min_severity)
    {:ok, prompt}
  end

  @doc """
  Reconcile status field edits and check that no incoming issues remain.

  Reads the `## Status` field from each projected issue file in incoming/
  and syncs the value back to the database. Then checks whether untriaged
  issues remain at the minimum severity.

  Returns:
  - `{:ok, :valid}` when no incoming issues at min severity remain
  - `{:ok, :invalid, feedback}` when untriaged issues remain
  """
  def evaluate(scope, task) do
    min_severity = get_min_severity(task)

    remaining = list_incoming_at_severity(scope, min_severity)

    case remaining do
      [] ->
        {:ok, :valid}

      issues ->
        names = Enum.map_join(issues, "\n", &"- `#{&1.title}`")

        {:ok, :invalid,
         "#{length(issues)} untriaged issue(s) remain at #{min_severity}+ severity:\n\n#{names}\n\nUse the `accept_issue` or `dismiss_issue` MCP tools for each remaining issue."}
    end
  end

  def dispatch(_node) do
    "Triage incoming QA issues at the configured minimum severity (default " <>
      "`:medium`). For each issue: read via `get_issue`, decide accept / " <>
      "dismiss / merge, and execute via `accept_issue` / `dismiss_issue` " <>
      "MCP tools. Use when incoming issues at or above the threshold remain."
  end

  # ============================================================================
  # Prompt Building
  # ============================================================================

  defp build_prompt([], min_severity) do
    """
    # Triage Issues

    No incoming issues found at #{min_severity}+ severity. Nothing to triage.
    """
  end

  defp build_prompt(_issues, min_severity) do
    """
    # Triage Issues

    You are triaging incoming QA issues at **#{min_severity}+** severity.

    ## Tools

    Use the following MCP tools to interact with issues:

    - `list_issues` — list issues (pass `status: "incoming"` to filter)
    - `get_issue` — read full issue details (pass the issue `id`)
    - `accept_issue` — accept a real issue (pass the issue `id`)
    - `dismiss_issue` — dismiss with a reason (pass `id` and `reason`)

    ## Goal

    Review all incoming issues and decide their disposition.

    1. **Discover issues** using `list_issues` with `status: "incoming"` and the appropriate `severity` filter
    2. **Read each issue** using `get_issue` with the issue `id`
    3. **Identify duplicates** — issues describing the same underlying problem
    4. **Decide a disposition** for each issue:
       - **Accept** — real issue, call `accept_issue` with the issue `id` **and a `story_id`**
       - **Dismiss** — not a real bug (test artifact, expected behavior, duplicate), call `dismiss_issue` with the issue `id` and `reason`
       - **Merge** — accept the best issue, dismiss the others with a reason noting the duplicate
    5. **Execute** each disposition using the tools above

    ## Accepting puts it on the graph — so link it

    `story_issues_resolved` is per-story. An unlinked issue gates nothing and
    reaches no agent. There are currently 21 accepted issues in that state.

    Ask which story's promise the defect breaks, and pass `story_id` **on the
    `accept_issue` call** — `accepted → accepted` is rejected, so a missed link
    needs repairing with `update_issue` afterwards.

    `story_id` is the **id, not the story number**, and the mistake is silent:
    story 983 has id 869, and passing 983 links to nothing with no error. Get it
    from `list_story_titles` (`ID:`).

    Genuinely project-level issues (tooling, harness) stay unlinked — but say so,
    or it reads as an oversight.

    Stop the session when all issues have been triaged.
    """
  end

  # ============================================================================
  # Severity Helpers
  # ============================================================================

  defp get_min_severity(%{state: %{"topic" => topic}}) when is_binary(topic) and topic != "" do
    parse_severity(topic)
  end

  defp get_min_severity(_task), do: :medium

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

  defp list_incoming_at_severity(scope, min_severity) do
    Issues.list_by_status(scope, :incoming)
    |> Enum.filter(fn issue ->
      Issue.severity_index(issue.severity) <= Issue.severity_index(min_severity)
    end)
  end
end
