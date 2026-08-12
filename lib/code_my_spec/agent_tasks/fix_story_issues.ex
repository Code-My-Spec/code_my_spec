defmodule CodeMySpec.AgentTasks.FixStoryIssues do
  @moduledoc """
  Resolve the accepted issues QA attributed to one story, before that story
  is released.

  The project-wide sibling is `AgentTasks.FixIssues`, which runs once at the
  end of the cycle over the whole queue. This one runs per story, between
  `qa_complete` and `deploy`, and sees only what QA filed against that story.

  Splitting them is the point. A defect QA found while testing story 42 is
  story 42's to fix, and holding it until the end-of-cycle sweep means
  releasing a story whose own QA pass raised a blocker. Conversely, an issue
  raised somewhere else — in another agent's territory, in a package waiting
  on a publish — has no business gating story 42, and would if this node read
  the project queue.
  """

  alias CodeMySpec.{Configurations, Issues, Paths}

  def dispatch(_node) do
    "Resolve the accepted issues QA filed against this story, at or above " <>
      "the project's `fix_issues_min_severity`, by reading, fixing, and " <>
      "calling `resolve_issue` per issue. Use when a story has cleared QA " <>
      "and still carries accepted issues of its own."
  end

  @doc """
  Build the fix prompt for this story's accepted issues.
  """
  def command(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      threshold = Configurations.fix_issues_min_severity(scope)
      issues = blocking_issues(scope, story_id, threshold)
      {:ok, build_prompt(story_id, issues, threshold)}
    end
  end

  @doc """
  Check that every accepted issue on this story at or above the configured
  threshold has been resolved.
  """
  def evaluate(scope, task) do
    with {:ok, story_id} <- get_story_id(task) do
      threshold = Configurations.fix_issues_min_severity(scope)

      case blocking_issues(scope, story_id, threshold) do
        [] ->
          {:ok, :valid}

        issues ->
          names = Enum.map_join(issues, "\n", &"- `#{&1.id}` — [#{&1.severity}] #{&1.title}")

          {:ok, :invalid,
           """
           #{length(issues)} unresolved accepted issue(s) on story #{story_id} at #{threshold}+ severity:

           #{names}

           Use the `resolve_issue` MCP tool with the issue `id` and `resolution` for each one you fix.
           """}
      end
    end
  end

  defp blocking_issues(scope, story_id, threshold) do
    Issues.list_by_story_status_and_min_severity(scope, story_id, :accepted, threshold)
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

  defp build_prompt(story_id, [], threshold) do
    """
    # Fix Story Issues — story #{story_id}

    No unresolved accepted issues on this story at #{threshold}+ severity.
    Call `evaluate_task` to record it and move on.
    """
  end

  defp build_prompt(story_id, issues, threshold) do
    listing = Enum.map_join(issues, "\n", &"- `#{&1.id}` — [#{&1.severity}] #{&1.title}")

    """
    # Fix Story Issues — story #{story_id}

    This story has cleared QA and carries **#{length(issues)} accepted
    issue(s)** at or above `#{threshold}`. Fix them before it is released.
    Issues below the threshold stay tracked and don't gate.

    #{listing}

    Only issues QA attributed to this story appear here. The rest of the
    project queue is handled once, at the end, by the project-level
    `issues_resolved` requirement — don't work it from this task.

    ## Read the playbook

    Read `fix_issues/workflow.md` via the `read_knowledge` MCP tool — the
    per-issue procedure (read → fix → resolve → test), scope-aware fixing
    rules (`app` / `qa` / `docs`), and the rule against silencing tests.

    ## QA context

    - **QA evidence for this story**: `#{Paths.qa_dir()}/#{story_id}/` —
      the brief, the failed result, and any screenshots that produced these
      issues.

    ## MCP tools

    - `get_issue` — read one issue's full detail, JIT, as you pick it up.
    - `resolve_issue` — `id` + `resolution`, required after every fix.

    Fix each issue, call `resolve_issue`, run the story's specs plus
    `mix test` to confirm nothing else broke, then call `evaluate_task`.
    """
  end
end
