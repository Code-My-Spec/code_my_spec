defmodule CodeMySpec.AgentTasks.TriageIssues do
  @moduledoc """
  Agent task for triaging incoming QA issues.

  Reviews all incoming issues from the database, decides dispositions
  (accept, dismiss, merge), and edits the `## Status` field in projected
  issue files from `incoming` to `accepted` or `dismissed`.

  Accepts an optional minimum severity via `task.state["topic"]` (default: :medium).
  Only issues at or above the specified severity are included in the triage.

  Two main functions:
  - `command/2` — Reads incoming issues from DB, builds triage prompt
  - `evaluate/2` — Reconciles status field changes to DB, checks that no incoming issues remain
  """

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.ProjectCoordinator

  @doc """
  Read incoming issues and build a triage prompt.

  Queries the database for incoming issues at or above the minimum severity
  and builds a prompt instructing the agent to review, deduplicate, and
  execute dispositions by editing the `## Status` field in projected files.

  Returns `{:ok, prompt_text}`
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
         "#{length(issues)} untriaged issue(s) remain at #{min_severity}+ severity:\n\n#{names}\n\nUse `.code_my_spec/tools/issues/accept-issue <id>` or `.code_my_spec/tools/issues/dismiss-issue <id> <reason>` for each remaining issue."}
    end
  end

  def orchestrate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate(__MODULE__, scope, session, opts)
  end

  def orchestrate_evaluate(scope, session, opts \\ []) do
    ProjectCoordinator.default_orchestrate_evaluate(__MODULE__, scope, session, opts)
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

  defp build_prompt(issues, min_severity) do
    grouped =
      issues
      |> Enum.group_by(& &1.severity)
      |> Enum.sort_by(fn {sev, _} -> Issue.severity_index(sev) end)

    issues_text =
      Enum.map_join(grouped, "\n\n", fn {severity, group} ->
        items =
          Enum.map_join(group, "\n", fn issue ->
            "- `#{issue.id}` — #{issue.title} (#{issue.severity})"
          end)

        "## #{String.capitalize(to_string(severity))} (#{length(group)})\n\n#{items}"
      end)

    """
    # Triage Issues

    You are triaging incoming QA issues at **#{min_severity}+** severity.

    ## Tools

    Use the following bash tools in `.code_my_spec/tools/issues/` to interact with issues:

    - `.code_my_spec/tools/issues/list-issues --status incoming` — list all incoming issues
    - `.code_my_spec/tools/issues/get-issue <id>` — read full issue details
    - `.code_my_spec/tools/issues/accept-issue <id>` — accept a real issue
    - `.code_my_spec/tools/issues/dismiss-issue <id> <reason>` — dismiss with a reason

    ## Goal

    Review all incoming issues and decide their disposition.

    1. **Read each issue** using `get-issue <id>` for the issues listed below
    2. **Identify duplicates** — issues describing the same underlying problem
    3. **Decide a disposition** for each issue:
       - **Accept** — real issue, run `.code_my_spec/tools/issues/accept-issue <id>`
       - **Dismiss** — not a real bug (test artifact, expected behavior, duplicate), run `.code_my_spec/tools/issues/dismiss-issue <id> "<reason>"`
       - **Merge** — accept the best issue, dismiss the others with a reason noting the duplicate
    4. **Execute** each disposition using the tools above

    ## Incoming Issues

    #{issues_text}

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
