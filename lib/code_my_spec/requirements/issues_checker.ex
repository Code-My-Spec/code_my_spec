defmodule CodeMySpec.Requirements.IssuesChecker do
  @moduledoc """
  Delegate checks for issue-related requirements.

  Used by RequirementCalculator via `:delegate` check_type.

  Two scopes, and the difference is the whole point:

    * `triaged?` / `resolved?` answer for the **project** — the queue as a
      whole, at the end of the cycle.
    * `story_triaged?` answer for **one story** — only
      what is attributed to it, gating that story's QA and nothing else.

  All but `story_triaged?` read the threshold from `ProjectConfiguration`, which is where
  `AgentTasks.FixIssues` already read it. They disagreed before: the task
  honoured a raised threshold and the checker hardcoded `:medium`, so a
  project set to `:high` got a requirement that could not clear and a task
  that evaluated green the moment it was started.
  """

  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues

  @doc """
  Check that nothing is left to triage: no incoming issue at or above the
  configured severity, and none on a story at any severity. See
  `Issues.list_triageable/2`.
  """
  @spec triaged?(term(), term()) :: {boolean(), map()}
  def triaged?(scope, _entity) do
    threshold = Configurations.fix_issues_min_severity(scope)

    case Issues.list_triageable(scope, threshold) do
      [] ->
        {true, %{status: triaged_status(threshold)}}

      triageable ->
        {false, %{reason: untriaged_reason(length(triageable), threshold)}}
    end
  end

  @doc "`triaged?/2`'s satisfied status, shared with `Requirements.Handlers` so both agree."
  def triaged_status(threshold),
    do: "No untriaged issues at #{threshold}+ severity or on any story"

  @doc "`triaged?/2`'s unsatisfied reason, shared with `Requirements.Handlers`."
  def untriaged_reason(count, threshold),
    do: "#{count} untriaged issue(s) at #{threshold}+ severity or on a story"

  @doc """
  Check that this story carries no incoming issue, at any severity.

  An untriaged finding on a story holds its QA: re-testing before anyone has
  decided whether the finding is real is the pass that told metric_flow story
  47 "nothing changed" (255f1dcd). Severity does not matter here — the
  threshold decides what must be *fixed*, not what must be *looked at*.
  """
  @spec story_triaged?(term(), term()) :: {boolean(), map()}
  def story_triaged?(scope, %{id: story_id}) do
    case Issues.list_filtered(scope, %{status: :incoming, story_id: story_id}) do
      [] -> {true, %{status: story_triaged_status()}}
      incoming -> {false, story_untriaged_details(incoming)}
    end
  end

  @doc "`story_triaged?/2`'s satisfied status, shared with `Requirements.Handlers`."
  def story_triaged_status, do: "No untriaged issues on this story"

  @doc "`story_triaged?/2`'s unsatisfied details, shared with `Requirements.Handlers`."
  def story_untriaged_details(incoming) do
    %{
      reason: "#{length(incoming)} untriaged issue(s) on this story",
      issues: Enum.map(incoming, &"#{&1.severity}: #{&1.title}")
    }
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
end
