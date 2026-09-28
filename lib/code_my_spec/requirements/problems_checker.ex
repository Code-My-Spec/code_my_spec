defmodule CodeMySpec.Requirements.ProblemsChecker do
  @moduledoc """
  Delegate check for a story's `problems_resolved` requirement.

  Story 1003, revised 2026-09-28: John wants a story's own working copy free
  of analyzer findings before QA spends a pass on it, not just before
  promotion — testing code the analyzers already know is broken produces
  defects that are really just problems restated, and a copy is expected to
  reach QA already clean, the same way it already has to reach promotion
  clean.

  Reuses the same always-blocking half of the query `Promotion`'s own gate
  reads (`ProblemRepository.list_project_problems/2`, `credo`/`compiler`
  findings, which `Promotion` documents as blocking "at any severity and
  whatever the stop hook's mode says"). Not the other half —
  `Validation.enforceable/2`, which mode-filters every other source's
  `:error`-severity findings — because `CodeMySpec.Validation` sits above
  `CodeMySpec.Requirements` in this project's boundary graph and a leaf
  calling up would be the same mistake `Promotion.RunningCopy`'s own presence
  in this context's deps exists to avoid making in the other direction. So
  "no problems" here is narrower than promotion's own definition — credo and
  compiler findings specifically — not a second, independently-drifting
  definition of the wider one.

  Scoped to the story's own working copy (`story.working_copy_id`), not the
  calling scope's active one — those two are frequently different (several
  agents, several copies, one project), and reading the wrong copy's
  problems against this story is exactly the bug class `Promotion`'s own
  gate already names and works around (`02796b61`).
  """

  alias CodeMySpec.Problems.ProblemRepository

  @always_block ~w(credo compiler)

  @doc """
  True when the story's own working copy carries no credo or compiler finding.

  Returns `{boolean, details}` for `RequirementCalculator`.
  """
  @spec resolved?(term(), term()) :: {boolean(), map()}
  def resolved?(scope, %{working_copy_id: working_copy_id}) do
    here = %{scope | active_working_copy_id: working_copy_id}

    case ProblemRepository.list_project_problems(here, sources: @always_block) do
      [] ->
        {true, %{status: "No blocking problems on this story's own working copy"}}

      problems ->
        {false, %{reason: "#{length(problems)} blocking problem(s) on this story's own working copy"}}
    end
  end
end
