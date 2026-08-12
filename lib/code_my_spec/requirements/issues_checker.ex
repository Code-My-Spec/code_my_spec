defmodule CodeMySpec.Requirements.IssuesChecker do
  @moduledoc """
  Delegate checks for issue-related requirements.

  Used by RequirementCalculator via `:delegate` check_type.

  Two scopes, and the difference is the whole point:

    * `triaged?` / `resolved?` answer for the **project** — the queue as a
      whole, at the end of the cycle.
    * `story_resolved?` answers for **one story** — only what QA attributed
      to it, gating that story's release and nothing else.

  All three read the threshold from `ProjectConfiguration`, which is where
  `AgentTasks.FixIssues` already read it. They disagreed before: the task
  honoured a raised threshold and the checker hardcoded `:medium`, so a
  project set to `:high` got a requirement that could not clear and a task
  that evaluated green the moment it was started.
  """

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues

  @doc "Check that no incoming issues at or above the configured severity remain untriaged."
  @spec triaged?(term(), term()) :: {boolean(), map()}
  def triaged?(scope, _entity) do
    threshold = Configurations.fix_issues_min_severity(scope)

    case Issues.list_by_status_and_min_severity(scope, :incoming, threshold) do
      [] -> {true, %{status: "No untriaged issues at #{threshold}+ severity"}}
      triageable -> {false, %{reason: "#{length(triageable)} untriaged #{threshold}+ issues"}}
    end
  end

  @doc "Check that no accepted issues at or above the configured severity remain unresolved."
  @spec resolved?(term(), term()) :: {boolean(), map()}
  def resolved?(scope, _entity) do
    threshold = Configurations.fix_issues_min_severity(scope)

    case Issues.list_by_status_and_min_severity(scope, :accepted, threshold) do
      [] -> {true, %{status: "No unresolved #{threshold}+ issues"}}
      unresolved -> {false, %{reason: "#{length(unresolved)} unresolved #{threshold}+ issues"}}
    end
  end

  @doc """
  Check that this story carries no accepted issue at or above the configured
  severity.

  Only issues QA attributed to the story count. An issue with no `story_id`
  is the project queue's problem, not this story's — it gates at
  `issues_resolved`, at the end, and must not hold a finished story hostage.
  """
  @spec story_resolved?(term(), term()) :: {boolean(), map()}
  def story_resolved?(scope, %{id: story_id}) do
    threshold = Configurations.fix_issues_min_severity(scope)

    case Issues.list_by_story_status_and_min_severity(scope, story_id, :accepted, threshold) do
      [] ->
        {true, %{status: "No unresolved #{threshold}+ issues on this story"}}

      unresolved ->
        {false,
         %{
           reason: "#{length(unresolved)} unresolved #{threshold}+ issue(s) on this story",
           issues: Enum.map(unresolved, &"#{&1.severity}: #{&1.title}")
         }}
    end
  end
end
