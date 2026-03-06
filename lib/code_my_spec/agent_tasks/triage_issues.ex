defmodule CodeMySpec.AgentTasks.TriageIssues do
  @moduledoc """
  Agent task for triaging incoming QA issues.

  Reviews all incoming issues from the database, decides dispositions
  (accept, dismiss, merge), and moves projected files to `accepted/` or `dismissed/`.

  Accepts an optional minimum severity argument (default: :medium) from
  `session.state["topic"]`. Only issues at or above the specified severity
  are included in the triage.

  Two main functions:
  - `command/3` — Reads incoming issues from DB, builds triage prompt
  - `evaluate/3` — Reconciles filesystem changes to DB, checks that no incoming issues remain
  """

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.{Issues, Paths}
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.ProjectCoordinator

  @doc """
  Read incoming issues and build a triage prompt.

  Queries the database for incoming issues at or above the minimum severity
  and builds a prompt instructing the agent to review, deduplicate, and
  execute dispositions by moving projected files.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, session, _opts \\ []) do
    min_severity = get_min_severity(session)
    issues = list_incoming_at_severity(scope, min_severity)

    prompt = build_prompt(issues, min_severity)
    {:ok, TaskMarker.build("TriageIssues", to_string(min_severity)) <> "\n\n" <> prompt}
  end

  @doc """
  Reconcile filesystem triage and check that no incoming issues remain.

  First reconciles the agent's file moves back to the database (files moved
  to accepted/ get accepted, files removed get dismissed), then checks
  whether untriaged issues remain.

  Returns:
  - `{:ok, :valid}` when no incoming issues at min severity remain
  - `{:ok, :invalid, feedback}` when untriaged issues remain
  """
  def evaluate(scope, session, _opts \\ []) do
    min_severity = get_min_severity(session)

    Issues.reconcile_triage(scope)

    remaining = list_incoming_at_severity(scope, min_severity)

    case remaining do
      [] ->
        {:ok, :valid}

      issues ->
        names = Enum.map_join(issues, "\n", &"- `#{&1.title}`")

        {:ok, :invalid,
         "#{length(issues)} untriaged issue(s) remain at #{min_severity}+ severity:\n\n#{names}\n\nReview each issue and move to accepted/ or dismissed/."}
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
          Enum.map_join(group, "\n\n", fn issue ->
            filename = Issues.projected_filename(issue)

            """
            ### `#{filename}`

            - **Title:** #{issue.title}
            - **Severity:** #{issue.severity}
            - **Scope:** #{issue.scope || :app}
            - **Story:** #{issue.story_id || "N/A"}

            #{issue.description}\
            """
          end)

        "## #{String.capitalize(to_string(severity))} (#{length(group)})\n\n#{items}"
      end)

    """
    # Triage Issues

    You are triaging incoming QA issues at **#{min_severity}+** severity.

    ## Goal

    Produce a clean `accepted/` folder with real, deduplicated issues. Your job:

    1. **Read all incoming issues** listed below
    2. **Identify duplicates** — issues describing the same underlying problem
    3. **Decide a disposition** for each issue:
       - **Accept** — real issue, move to `#{Paths.issues_accepted_dir()}/`
       - **Dismiss** — not a real bug (test artifact, expected behavior, duplicate), move to `#{Paths.issues_dismissed_dir()}/`
       - **Merge** — consolidate evidence from duplicates into one accepted issue, dismiss the others
    4. **Execute** — move files using `Write` to the target directory and delete from `incoming/`

    Each issue may have a `## Scope` section (`app`, `qa`, or `docs`). Preserve the scope
    when moving files. If an issue is missing a scope section, default to `app`.

    When merging duplicates: pick the best title, consolidate description and evidence into
    one accepted issue file, and dismiss the rest with a note about which issue they merged into.

    Ensure the `accepted/` and `dismissed/` directories exist before writing (create them if needed).

    ## Incoming Issues

    #{issues_text}

    ## Directories

    - Incoming: `#{Paths.issues_incoming_dir()}/`
    - Accepted: `#{Paths.issues_accepted_dir()}/`
    - Dismissed: `#{Paths.issues_dismissed_dir()}/`

    Stop the session when all issues have been triaged.
    """
  end

  # ============================================================================
  # Severity Helpers
  # ============================================================================

  defp get_min_severity(%{state: %{"topic" => topic}}) when is_binary(topic) and topic != "" do
    case String.downcase(String.trim(topic)) do
      "critical" -> :critical
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      "info" -> :info
      _ -> :medium
    end
  end

  defp get_min_severity(_session), do: :medium

  defp list_incoming_at_severity(scope, min_severity) do
    Issues.list_by_status(scope, :incoming)
    |> Enum.filter(fn issue ->
      Issue.severity_index(issue.severity) <= Issue.severity_index(min_severity)
    end)
  end
end
