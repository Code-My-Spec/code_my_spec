defmodule CodeMySpec.AgentTasks.FixIssues do
  @moduledoc """
  Resolve every accepted QA issue.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/fix_issues.spec.md`.
  """

  alias CodeMySpec.{Issues, Paths}
  alias CodeMySpec.Issues.Issue

  def orchestrate(_node) do
    "Resolve every accepted QA issue by reading, fixing, and calling " <>
      "`resolve_issue` per issue. No severity filter — whatever triage " <>
      "accepted gets fixed. Use when `issues_triaged` is satisfied and " <>
      "accepted issues remain."
  end

  @doc """
  Read accepted issues and build a fix prompt. Returns `{:ok, prompt_text}`.
  """
  def command(scope, _task) do
    unresolved = Issues.list_by_status(scope, :accepted)
    {:ok, build_prompt(unresolved)}
  end

  @doc """
  Check that every accepted issue has been resolved.
  """
  def evaluate(scope, _task) do
    case Issues.list_by_status(scope, :accepted) do
      [] ->
        {:ok, :valid}

      issues ->
        names = Enum.map_join(issues, "\n", &"- `#{&1.id}` — #{&1.title}")

        {:ok, :invalid,
         "#{length(issues)} unresolved accepted issue(s):\n\n#{names}\n\nUse the `resolve_issue` MCP tool with the issue `id` and `resolution` for each fixed issue."}
    end
  end

  # ============================================================================
  # Prompt assembly. Procedure detail lives in the framework knowledge library
  # at `fix_issues/workflow.md` (read via the `read_knowledge` MCP tool) —
  # pointed at via the playbook section rather than inlined here.
  # ============================================================================

  defp build_prompt([]) do
    """
    # Fix Issues

    No unresolved accepted issues. Nothing to fix.
    """
  end

  defp build_prompt(unresolved) do
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

    You are fixing every accepted QA issue. The working set is whatever triage
    promoted to `accepted`; there is no severity filter at this layer.

    ## Read the playbook

    Read `fix_issues/workflow.md` via the `read_knowledge` MCP tool —
    per-issue procedure (read → fix → resolve → test), scope-aware fixing
    rules (`app` / `qa` / `docs`), regression-handling rules (no silencing
    tests), and MCP tool usage.

    ## QA context

    - **QA plan**: `#{Paths.qa_plan()}` — server startup, seeds, auth.
    - **QA evidence**: `#{Paths.qa_dir()}/<story_id>/` — failed results,
      screenshots, briefs per story.

    ## MCP tools

    - `get_issue` — read full issue details by id.
    - `resolve_issue` — mark resolved with `id` + `resolution` (required
      after every fix).
    - `list_issues` — re-check the accepted list.

    ## Unresolved issues

    #{issues_text}

    ## Directory

    Accepted issues: `#{Paths.issues_accepted_dir()}/`

    Fix each issue, call `resolve_issue`, run `mix test` to verify nothing
    else broke, then stop.
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
end
