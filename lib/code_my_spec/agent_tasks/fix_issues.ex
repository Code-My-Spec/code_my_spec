defmodule CodeMySpec.AgentTasks.FixIssues do
  @moduledoc """
  Agent task for fixing accepted QA issues.

  Reads accepted issues from the database, filters to those at or above the
  specified severity that haven't been resolved, and builds a prompt instructing
  the agent to fix each issue and document the resolution.

  Accepts an optional minimum severity argument (default: :medium) from
  `session.state["topic"]`.

  Two main functions:
  - `command/3` — Reads accepted issues from DB, builds fix prompt
  - `evaluate/3` — Reconciles resolutions from files to DB, checks that all medium+ issues are resolved
  """

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.{Issues, Paths}
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.ProjectCoordinator

  @doc """
  Read accepted unresolved issues and build a fix prompt.

  Queries the database for accepted issues at or above the minimum severity
  that lack a resolution, and builds a prompt with fix instructions.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, session, _opts \\ []) do
    min_severity = get_min_severity(session)
    unresolved = list_unresolved_at_severity(scope, min_severity)

    prompt = build_prompt(unresolved, min_severity)
    {:ok, TaskMarker.build("FixIssues", to_string(min_severity)) <> "\n\n" <> prompt}
  end

  @doc """
  Reconcile resolutions and check that all medium+ accepted issues are resolved.

  First reconciles agent-written `## Resolution` sections from projected files
  back to the database, then checks whether unresolved blocking issues remain.

  Uses :medium as the blocking threshold regardless of the session's min_severity.

  Returns:
  - `{:ok, :valid}` when no blocking unresolved issues remain
  - `{:ok, :invalid, feedback}` when unresolved blocking issues exist
  """
  def evaluate(scope, _session, _opts \\ []) do
    Issues.reconcile_resolutions(scope)

    remaining = list_unresolved_at_severity(scope, :medium)

    case remaining do
      [] ->
        {:ok, :valid}

      issues ->
        names = Enum.map_join(issues, "\n", &"- `#{&1.title}`")

        {:ok, :invalid,
         "#{length(issues)} unresolved medium+ issue(s):\n\n#{names}\n\nFix each issue and add a ## Resolution section describing what was done."}
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
    # Fix Issues

    No unresolved accepted issues found at #{min_severity}+ severity. Nothing to fix.
    """
  end

  defp build_prompt(unresolved, min_severity) do
    grouped_by_scope =
      unresolved
      |> Enum.group_by(& &1.scope)
      |> Enum.sort_by(fn {scope, _} -> to_string(scope) end)

    issues_text =
      Enum.map_join(grouped_by_scope, "\n\n", fn {scope, group} ->
        sorted = Enum.sort_by(group, &Issue.severity_index(&1.severity))
        items = format_issue_items(sorted)

        "## Scope: #{scope} (#{length(group)})\n\n#{items}"
      end)

    """
    # Fix Issues

    You are fixing accepted QA issues at **#{min_severity}+** severity.

    ## Goal

    For each issue below:

    1. **Understand the problem** — read the issue description and source QA result
    2. **Fix the code** — use subagents (Agent tool) for the actual fix work. Group related issues
       into one subagent if they share a root cause. Each subagent should:
       - Read the relevant source files
       - Make the fix
       - Verify the fix works
    3. **Add a `## Resolution` section** to each issue file describing what was done:
       - Summary of the fix
       - Files changed
       - How the fix was verified
    4. **Run tests** after all fixes to verify nothing is broken: `mix test`

    ## Scope-Aware Fixing

    Issues have a scope indicating what to fix:
    - **app** — Fix application code (controllers, live views, schemas, etc.)
    - **qa** — Fix QA infrastructure (seed scripts, auth scripts, QA plan, test tooling)
    - **docs** — Fix documentation (specs, README, user stories)

    Read the scope before fixing — a `qa` issue means the seeds or scripts need updating, not the app code.

    ## QA Results

    Issue source references point to QA result files in `#{Paths.qa_dir()}/`. Read those
    files for additional context, reproduction steps, and screenshots.

    ## Unresolved Issues

    #{issues_text}

    ## Directory

    Accepted issues: `#{Paths.issues_accepted_dir()}/`

    Fix the issues, add resolution sections, and run tests to verify.
    """
  end

  defp format_issue_items(issues) do
    Enum.map_join(issues, "\n\n", fn issue ->
      filename = Issues.projected_filename(issue)
      source_ref = if issue.source_path, do: "`#{issue.source_path}`", else: nil

      """
      ### `#{filename}`

      #{if source_ref, do: "**Source:** #{source_ref}\n", else: ""}
      - **Title:** #{issue.title}
      - **Severity:** #{issue.severity}
      - **Scope:** #{issue.scope || :app}
      - **Story:** #{issue.story_id || "N/A"}

      #{issue.description}\
      """
    end)
  end

  # ============================================================================
  # Helpers
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

  defp list_unresolved_at_severity(scope, min_severity) do
    Issues.list_by_status(scope, :accepted)
    |> Enum.filter(fn issue ->
      Issue.severity_index(issue.severity) <= Issue.severity_index(min_severity)
    end)
  end
end
