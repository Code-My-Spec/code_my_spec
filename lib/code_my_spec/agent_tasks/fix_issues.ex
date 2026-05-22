defmodule CodeMySpec.AgentTasks.FixIssues do
  @moduledoc """
  Resolve every accepted QA issue.

  See spec: `.code_my_spec/spec/code_my_spec/agent_tasks/fix_issues.spec.md`.
  """

  alias CodeMySpec.{Issues, Paths}

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
    count = scope |> Issues.list_by_status(:accepted) |> length()
    {:ok, build_prompt(count)}
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

  defp build_prompt(0) do
    """
    # Fix Issues

    No unresolved accepted issues. Nothing to fix.
    """
  end

  defp build_prompt(count) do
    """
    # Fix Issues

    You are fixing every accepted QA issue. The working set is whatever triage
    promoted to `accepted`; there is no severity filter at this layer.

    There are **#{count} accepted issue(s)** to work through. Discover them
    via `list_issues` (status: "accepted") — DO NOT expect the prompt to
    embed the backlog; on a large backlog the bodies overflow the response
    window. Read each issue's detail JIT with `get_issue` only when you're
    about to fix it.

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

    - `list_issues` — discover the accepted backlog (status: "accepted").
    - `get_issue` — read full issue details by id, one at a time.
    - `resolve_issue` — mark resolved with `id` + `resolution` (required
      after every fix).

    Fix each issue, call `resolve_issue`, run `mix test` to verify nothing
    else broke, then stop.
    """
  end
end
