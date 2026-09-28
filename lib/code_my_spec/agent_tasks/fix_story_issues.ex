defmodule CodeMySpec.AgentTasks.FixStoryIssues do
  @moduledoc """
  Resolve the accepted issues QA attributed to one story, before that story
  is released.

  The project-wide sibling is `AgentTasks.FixIssues`, which runs once at the
  end of the cycle over the whole queue. This one runs per story and sees
  only what QA filed against that story. Its own position in the graph moved
  ahead of `qa_complete` on 2026-09-23 (this text was stale about that until
  story 1003, 2026-09-28) — issues get cleared as soon as a story's specs are
  green, not after a QA pass.

  Splitting them is the point. A defect QA found while testing story 42 is
  story 42's to fix, and holding it until the end-of-cycle sweep means
  releasing a story whose own QA pass raised a blocker. Conversely, an issue
  raised somewhere else — in another agent's territory, in a package waiting
  on a publish — has no business gating story 42, and would if this node read
  the project queue.

  Story 1003, revised 2026-09-28: also resolves `problems_resolved` —
  `Requirements.ProblemsChecker`'s own node, checking credo/compiler findings
  on the story's own working copy, now sits ahead of `qa_complete` alongside
  this one. It has no dedicated task of its own: reusing this one keeps a
  story blocked only by a bare analyzer finding from being offered a task
  whose prompt names nothing it can act on, which is exactly the "claim the
  task, find no issues, tap out, get offered the same task again" spin this
  project has been burned by before (94327fe2). `evaluate/2` checks both, so
  a story cannot read as done here while either kind of blocker remains.
  """

  alias CodeMySpec.{Configurations, Issues, Paths, Problems, Stories}

  def dispatch(_node) do
    "Resolve the accepted issues QA filed against this story, at or above " <>
      "the project's `fix_issues_min_severity`, by reading, fixing, and " <>
      "calling `resolve_issue` per issue — and clear any credo/compiler " <>
      "finding on this story's own working copy alongside them. Use when a " <>
      "story is not yet offered for QA because it carries either."
  end

  @always_block_problem_sources ~w(credo compiler)

  @doc """
  Build the fix prompt for this story's accepted issues and analyzer problems.
  """
  def command(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      threshold = Configurations.fix_issues_min_severity(scope)
      issues = blocking_issues(scope, story_id, threshold)
      problems = blocking_problems(scope, story_id)
      {:ok, build_prompt(story_id, issues, threshold, problems)}
    end
  end

  @doc """
  Check that every accepted issue on this story at or above the configured
  threshold has been resolved, and that its own working copy carries no
  credo or compiler finding.
  """
  def evaluate(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      threshold = Configurations.fix_issues_min_severity(scope)
      issues = blocking_issues(scope, story_id, threshold)
      problems = blocking_problems(scope, story_id)

      case {issues, problems} do
        {[], []} ->
          {:ok, :valid}

        {issues, problems} ->
          {:ok, :invalid, invalid_message(story_id, issues, threshold, problems)}
      end
    end
  end

  defp blocking_issues(scope, story_id, threshold) do
    Issues.list_by_story_status_and_min_severity(scope, story_id, :accepted, threshold)
  end

  # Same source list `Requirements.ProblemsChecker` gates `problems_resolved`
  # on — scoped to the story's own working copy, not whichever copy happens
  # to be asking, for the same reason that checker is (`02796b61`).
  defp blocking_problems(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      %{working_copy_id: working_copy_id} when is_binary(working_copy_id) ->
        here = %{scope | active_working_copy_id: working_copy_id}
        Problems.list_project_problems(here, sources: @always_block_problem_sources)

      _ ->
        []
    end
  end

  defp invalid_message(story_id, issues, threshold, problems) do
    [
      issues_section(story_id, issues, threshold),
      problems_section(problems)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp issues_section(_story_id, [], _threshold), do: nil

  defp issues_section(story_id, issues, threshold) do
    names = Enum.map_join(issues, "\n", &"- `#{&1.id}` — [#{&1.severity}] #{&1.title}")

    """
    #{length(issues)} unresolved accepted issue(s) on story #{story_id} at #{threshold}+ severity:

    #{names}

    Use the `resolve_issue` MCP tool with the issue `id` and `resolution` for each one you fix.
    """
  end

  defp problems_section([]), do: nil

  defp problems_section(problems) do
    names =
      Enum.map_join(problems, "\n", fn p ->
        "- [#{p.source}] #{p.file_path}:#{p.line} — #{p.message}"
      end)

    """
    #{length(problems)} credo/compiler finding(s) on this story's own working copy:

    #{names}

    These block `problems_resolved` and `qa_complete` regardless of issue status. Fix them directly in the code.
    """
  end

  defp get_story_id(%{story_id: story_id}) when not is_nil(story_id) do
    case Integer.parse(to_string(story_id)) do
      {id, _} -> {:ok, id}
      :error -> {:error, {:invalid_story_id, "Expected a numeric story ID, got #{inspect(story_id)}."}}
    end
  end

  defp get_story_id(_task) do
    {:error,
     {:story_id_required,
      "FixStoryIssues is a story-scoped requirement. Call `start_task` with entity_type=`story` and the story's id."}}
  end

  defp build_prompt(story_id, [], _threshold, []) do
    """
    # Fix Story Issues — story #{story_id}

    No unresolved accepted issues and no analyzer problems on this story's
    own working copy. Call `evaluate_task` to record it and move on.
    """
  end

  defp build_prompt(story_id, issues, threshold, problems) do
    issues_listing =
      case issues do
        [] ->
          "None."

        issues ->
          Enum.map_join(issues, "\n", &"- `#{&1.id}` — [#{&1.severity}] #{&1.title}")
      end

    problems_listing =
      case problems do
        [] ->
          "None."

        problems ->
          Enum.map_join(problems, "\n", fn p ->
            "- [#{p.source}] #{p.file_path}:#{p.line} — #{p.message}"
          end)
      end

    """
    # Fix Story Issues — story #{story_id}

    This story is blocked from QA/release by #{length(issues)} accepted
    issue(s) at or above `#{threshold}` severity and/or #{length(problems)}
    credo/compiler finding(s) on its own working copy. Fix whichever apply.
    Issues below the threshold stay tracked and don't gate.

    ## Accepted issues

    #{issues_listing}

    Only issues QA attributed to this story appear here. The rest of the
    project queue is handled once, at the end, by the project-level
    `issues_resolved` requirement — don't work it from this task.

    ## Analyzer findings (credo/compiler)

    #{problems_listing}

    These are checked against `problems_resolved`, a separate requirement
    from issues — both have to clear before this task is done.

    ## Read the playbook

    Read `fix_issues/workflow.md` via the `read_knowledge` MCP tool — the
    per-issue procedure (read → fix → resolve → test), scope-aware fixing
    rules (`app` / `qa` / `docs`), and the rule against silencing tests.

    ## QA context

    - **QA evidence for this story**: `#{Paths.qa_dir()}/#{story_id}/` —
      the brief, the failed result, and any screenshots that produced these
      issues, if any exist yet.

    ## MCP tools

    - `get_issue` — read one issue's full detail, JIT, as you pick it up.
    - `resolve_issue` — `id` + `resolution`, required after every issue fix.

    Fix each issue and finding, call `resolve_issue` for issues, run the
    story's specs plus `mix test`/`mix credo` to confirm nothing else broke,
    then call `evaluate_task`.
    """
  end
end
