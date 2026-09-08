defmodule CodeMySpec.Requirements.SpecsPassingChecker do
  @moduledoc """
  Delegate check for a story's `bdd_specs_passing` requirement.

  `specs_ready` is a latch and the latch is still the answer: a green run sets
  it, and a *stale* run must never clear it. That asymmetry is why the node can
  exist at all — bab2f792 removed it because freshness was re-evaluated forever,
  so nearly any edit dropped the story back to "analysis pending" and clamped
  `qa_complete` behind it.

  What the field alone could not do is notice that it was never true. Both
  previous versions of the gate that sets it matched a spex problem to a story
  by parsing the spec's *directory name*, and spex directories are named from
  `story.number` in some places and `story.id` in others. The comparison
  silently matched nothing for whichever convention it was not written for, the
  gate read "this story has no failing specs", and it latched.

  Measured on Broken Oaths 2026-09-08: 38 of 54 spec directories were
  id-prefixed, and 47 of 61 stories carried `specs_ready: true` over 127 red
  specs for features nobody had written. Ten of those stories still had live
  failures against their own spec files. Because the graph read the field and
  the field said yes, `bdd_specs_passing` was not actionable for any of them —
  so the only coding work left on the board was writing specs for the stories
  that had none, which is exactly what the fleet did.

  So the check is the field **and** a contradiction test: a fresh spex run
  showing this story's own spec files failing means the latch is wrong,
  whatever it says. Staleness still cannot clear it — `Analysis.fresh?/2` gates
  the whole test, so an out-of-date run leaves a latched story latched.

  Matching is by `files.story_id`, resolved at sync time from the spec itself,
  which was correct for every directory of both conventions.
  """

  alias CodeMySpec.Analysis
  alias CodeMySpec.Files
  alias CodeMySpec.Problems

  @doc """
  True when the story's specs-ready latch is set and nothing contradicts it.

  Returns `{boolean, details}` for `RequirementCalculator`.
  """
  @spec passing?(term(), term()) :: {boolean(), map()}
  def passing?(_scope, %{specs_ready: ready}) when ready != true do
    {false, %{reason: "Specs have not gone green on a fresh spex run yet"}}
  end

  def passing?(scope, %{id: story_id}) do
    if Analysis.fresh?(scope, "spex") do
      check_against_fresh_run(scope, story_id)
    else
      # No current run to argue with. The latch stands, which is the whole
      # point of it being a latch.
      {true, %{status: "Specs ready (no fresh spex run to re-check against)"}}
    end
  end

  defp check_against_fresh_run(scope, story_id) do
    case failing_own_specs(scope, story_id) do
      [] ->
        {true, %{status: "Specs ready and green on the current spex run"}}

      problems ->
        {false,
         %{
           reason:
             "Marked specs-ready, but #{length(problems)} of this story's own specs " <>
               "fail on the current spex run — the latch was set without them passing"
         }}
    end
  end

  defp failing_own_specs(scope, story_id) do
    story_paths =
      scope
      |> Files.list_story_files(story_id)
      |> Enum.filter(&(&1.role == :bdd_spec))
      |> MapSet.new(& &1.path)

    if Enum.empty?(story_paths) do
      []
    else
      scope
      |> Problems.list_project_problems(source: "spex", severity: :error)
      |> Enum.filter(&MapSet.member?(story_paths, &1.file_path))
    end
  end
end
