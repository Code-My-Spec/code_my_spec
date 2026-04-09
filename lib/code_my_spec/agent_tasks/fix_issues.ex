defmodule CodeMySpec.AgentTasks.FixIssues do
  @moduledoc """
  Agent task for fixing accepted QA issues.

  Reads accepted issues from the database, filters to those at or above the
  specified severity that haven't been resolved, and builds a prompt instructing
  the agent to fix each issue and document the resolution.

  Accepts an optional minimum severity via `task.state["topic"]` (default: :medium).

  Two main functions:
  - `command/2` — Reads accepted issues from DB, builds fix prompt
  - `evaluate/2` — Checks that all medium+ issues are resolved (via tool or file fallback)
  """

  alias CodeMySpec.{Issues, Paths}
  alias CodeMySpec.Issues.Issue


  @doc """
  Read accepted unresolved issues and build a fix prompt.

  Queries the database for accepted issues at or above the minimum severity
  that lack a resolution, and builds a prompt with fix instructions.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, task) do
    min_severity = get_min_severity(task)
    unresolved = list_unresolved_at_severity(scope, min_severity)

    prompt = build_prompt(unresolved, min_severity)
    {:ok, prompt}
  end

  @doc """
  Check that all medium+ accepted issues are resolved.

  Falls back to reconciling file-based resolutions for any the agent missed
  with the tool, then checks whether unresolved blocking issues remain.

  Uses :medium as the blocking threshold regardless of the session's min_severity.

  Returns:
  - `{:ok, :valid}` when no blocking unresolved issues remain
  - `{:ok, :invalid, feedback}` when unresolved blocking issues exist
  """
  def evaluate(scope, _task) do
    remaining = list_unresolved_at_severity(scope, :medium)

    case remaining do
      [] ->
        {:ok, :valid}

      issues ->
        names = Enum.map_join(issues, "\n", &"- `#{&1.title}`")

        {:ok, :invalid,
         "#{length(issues)} unresolved medium+ issue(s):\n\n#{names}\n\nUse `.code_my_spec/tools/issues/resolve-issue <id> \"<resolution>\"` for each fixed issue."}
    end
  end

  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
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

    ## Tools

    Use the following bash tools in `.code_my_spec/tools/issues/` to interact with issues:

    - `.code_my_spec/tools/issues/get-issue <id>` — read full issue details
    - `.code_my_spec/tools/issues/resolve-issue <id> "<resolution>"` — mark as resolved with description of fix

    ## Goal

    For each issue below:

    1. **Understand the problem** — read the issue description and source QA result
    2. **Fix the code** — use subagents (Agent tool) for the actual fix work. Group related issues
       into one subagent if they share a root cause. Each subagent should:
       - Read the relevant source files
       - Make the fix
       - Verify the fix works
    3. **Resolve the issue** — run `.code_my_spec/tools/issues/resolve-issue <id> "<resolution>"` with a summary of:
       - What was fixed
       - Files changed
       - How the fix was verified
    4. **Run tests** after all fixes to verify nothing is broken: `mix test`

    ## Scope-Aware Fixing

    Issues have a scope indicating what to fix:
    - **app** — Fix application code (controllers, live views, schemas, etc.)
    - **qa** — Fix QA infrastructure (seed scripts, auth scripts, QA plan, test tooling)
    - **docs** — Fix documentation (specs, README, user stories)

    Read the scope before fixing — a `qa` issue means the seeds or scripts need updating, not the app code.

    ## QA Context

    - **QA plan:** `#{Paths.qa_plan()}` — server startup, seeds, auth strategy
    - **QA results:** `#{Paths.qa_dir()}/{story_id}/` — failed results, screenshots, briefs

    Read the QA plan for how to start the server and run seeds if you need to verify fixes.
    Read the failed result and screenshots for each issue's story to understand the reproduction.

    ## Unresolved Issues

    #{issues_text}

    ## Directory

    Accepted issues: `#{Paths.issues_accepted_dir()}/`

    Fix the issues, resolve them with the tool, and run tests to verify.
    """
  end

  defp format_issue_items(issues) do
    Enum.map_join(issues, "\n\n", fn issue ->
      source_ref = if issue.source_path, do: "**Source:** `#{issue.source_path}`\n", else: ""

      qa_dir_ref =
        if issue.story_id,
          do: "**QA evidence:** `#{Paths.qa_dir()}/#{issue.story_id}/`\n",
          else: ""

      """
      ### Issue #{issue.id}: #{issue.title}

      #{source_ref}#{qa_dir_ref}\
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

  defp list_unresolved_at_severity(scope, min_severity) do
    Issues.list_by_status(scope, :accepted)
    |> Enum.filter(fn issue ->
      Issue.severity_index(issue.severity) <= Issue.severity_index(min_severity)
    end)
  end
end
