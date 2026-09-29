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

  e1174640: only a promote of the story sets the latch now, and the promote is
  downstream of this requirement. An unlatched story is therefore satisfied by
  a fresh run showing its own linked specs green, not by the field.
  """

  alias CodeMySpec.Analysis
  alias CodeMySpec.Files
  alias CodeMySpec.Problems

  @doc """
  True when the story's specs-ready latch is set and nothing contradicts it.

  Returns `{boolean, details}` for `RequirementCalculator`.
  """
  @spec passing?(term(), term()) :: {boolean(), map()}
  def passing?(scope, %{specs_ready: ready, id: story_id}) when ready != true do
    unlatched(scope, story_id, Analysis.fresh?(scope, "spex"))
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

  @doc """
  Same as `passing?/2`, but takes the requirement graph's preloaded context.

  `Analysis.fresh?/2` computes its fingerprint via `Fingerprint.current/2`,
  which re-fetches every File row for the project — `Files.list_files/1`,
  the same full-table read `Preloader.load/1` already did once. This
  requirement is checked once per story, so on a project with any real
  number of stories, `passing?/2` was paying that full-table fetch again
  for every single one: measured on this project (708492f9), 118 stories ×
  ~390ms — 45.9s of a 50.8s graph computation, on a codebase where every
  other check combined cost under a second. `ctx.analysis_fresh` is the
  same answer, computed once in the preload this graph already ran.

  `RequirementCalculator`'s delegate dispatch calls this arity whenever it
  has a context to hand it (every call inside `compute_graph/1`);
  `passing?/2` remains the fallback for a caller with none.
  """
  @spec passing?(term(), term(), map()) :: {boolean(), map()}
  def passing?(scope, %{specs_ready: ready, id: story_id}, %{analysis_fresh: fresh})
      when ready != true and is_map(fresh) do
    unlatched(scope, story_id, Map.get(fresh, "spex", false))
  end

  def passing?(scope, %{id: story_id}, %{analysis_fresh: fresh}) when is_map(fresh) do
    if Map.get(fresh, "spex", false) do
      check_against_fresh_run(scope, story_id)
    else
      {true, %{status: "Specs ready (no fresh spex run to re-check against)"}}
    end
  end

  def passing?(scope, entity, _ctx), do: passing?(scope, entity)

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

  # Not latched. Since e1174640 only a promote of the story latches it, and
  # the promote sits downstream of this requirement — so reading the latch
  # alone here would make the chain unsatisfiable. A fresh run showing the
  # story's own specs green satisfies it; a stale run, no linked specs, or a
  # red one does not.
  defp unlatched(_scope, _story_id, false),
    do: {false, %{reason: "Specs have not gone green on a fresh spex run yet"}}

  defp unlatched(scope, story_id, true) do
    paths = own_spec_paths(scope, story_id)

    cond do
      Enum.empty?(paths) ->
        {false, %{reason: "No spec files are linked to this story"}}

      failing(scope, paths) == [] ->
        {true, %{status: "Specs green on the current spex run (latched when promoted)"}}

      true ->
        {false, %{reason: "This story's own specs fail on the current spex run"}}
    end
  end

  defp failing_own_specs(scope, story_id) do
    case own_spec_paths(scope, story_id) do
      [] -> []
      paths -> failing(scope, paths)
    end
  end

  defp own_spec_paths(scope, story_id) do
    scope
    |> Files.list_story_files(story_id)
    |> Enum.filter(&(&1.role == :bdd_spec))
    |> Enum.map(& &1.path)
  end

  defp failing(scope, paths) do
    paths = MapSet.new(paths)

    scope
    |> Problems.list_project_problems(source: "spex", severity: :error)
    |> Enum.filter(&MapSet.member?(paths, &1.file_path))
  end
end
