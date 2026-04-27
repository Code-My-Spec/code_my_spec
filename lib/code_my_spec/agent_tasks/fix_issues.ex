defmodule CodeMySpec.AgentTasks.FixIssues do
  @moduledoc """
  Agent task for fixing accepted QA issues.

  Reads every accepted issue from the database and builds a prompt
  instructing the agent to fix each one and document the resolution.
  No severity filter — whatever made it past triage gets fixed
  (story 608, rule 1).

  Two main functions:
  - `command/2` — Reads accepted issues from DB, builds fix prompt
  - `evaluate/2` — Checks that every accepted issue has been resolved
  """

  alias CodeMySpec.{Issues, Paths}
  alias CodeMySpec.Issues.Issue

  @doc """
  Read accepted issues and build a fix prompt.

  Returns `{:ok, prompt_text}`
  """
  def command(scope, _task) do
    unresolved = Issues.list_by_status(scope, :accepted)
    prompt = build_prompt(unresolved)
    {:ok, prompt}
  end

  @doc """
  Check that every accepted issue has been resolved.

  Returns:
  - `{:ok, :valid}` when no accepted issues remain
  - `{:ok, :invalid, feedback}` when accepted issues exist; feedback
    names each remaining issue and instructs the agent to call
    `resolve_issue`.
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

  def orchestrate(node) do
    "Call `start_task` with requirement `#{node.name}` for #{node.entity_type} `#{node.entity_id}` (#{node.entity_name})"
  end

  # ============================================================================
  # Prompt Building
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

    You are fixing every accepted QA issue. The working set is whatever
    triage promoted to `accepted`; there is no severity filter at this
    layer.

    ## Tools

    Use the following MCP tools to interact with issues:

    - `get_issue` — read full issue details (pass the issue `id`)
    - `resolve_issue` — mark as resolved with description of fix (pass `id` and `resolution`)

    ## Goal

    For each issue below:

    1. **Understand the problem** — read the issue description and source QA result
    2. **Fix the code** — use subagents (Agent tool) for the actual fix work. Group related issues
       into one subagent if they share a root cause. Each subagent should:
       - Read the relevant source files
       - Make the fix
       - Verify the fix works
    3. **Resolve the issue** — call `resolve_issue` with the issue `id` and a `resolution` summary of:
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

    ## Regressions

    If a fix breaks a previously-passing test, that's a regression. Fix
    the regression in source code — never silence it. Specifically:

    - **Do not** add `@tag :pending` or `@tag :skip` to a failing test
      to make it stop running.
    - **Do not** weaken assertions to make a failing test pass.
    - **Do not** delete a failing test rather than diagnose why it
      broke.

    Diagnose the actual cause, fix the offending code, and re-run
    `mix test` until it's green before calling `resolve_issue`.

    ## QA Context

    - **QA plan:** `#{Paths.qa_plan()}` — server startup, seeds, auth strategy
    - **QA results:** `#{Paths.qa_dir()}/{story_id}/` — failed results, screenshots, briefs

    Read the QA plan for how to start the server and run seeds if you need to verify fixes.
    Read the failed result and screenshots for each issue's story to understand the reproduction.

    ## Unresolved Issues

    #{issues_text}

    ## Directory

    Accepted issues: `#{Paths.issues_accepted_dir()}/`

    Fix the issues, resolve them with `resolve_issue`, and run tests to verify.
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
