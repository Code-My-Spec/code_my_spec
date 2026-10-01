defmodule CodeMySpec.Requirements.SpecsPassingChecker do
  @moduledoc """
  Delegate check for a story's `bdd_specs_passing` requirement.

  `specs_ready` is a latch and the latch is still the answer: a promote sets
  it, and a copy with no spex run must never clear it. That is why the node can
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

  So the check is the field **and** a contradiction test: the latest completed
  spex run showing this story's own spec files failing means the latch is
  wrong, whatever it says. No completed run at all leaves a latched story
  latched — there is nothing to contradict it with.

  The latest completed run answers, however old (28d72f8a). Whether it ran
  against the current code is the promote gate's question, not this one's —
  analysis and requirements are orthogonal, so a run being behind the code
  never hides or withholds an answer here.

  Matching is by `files.story_id`, resolved at sync time from the spec itself,
  which was correct for every directory of both conventions.

  e1174640: only a promote of the story sets the latch now, and the promote is
  downstream of this requirement. An unlatched story is therefore satisfied by
  the latest spex run showing its own linked specs green, not by the field.
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
    if answered?(scope),
      do: unlatched(scope, story_id),
      else: {false, %{reason: "No spex run has completed on this working copy yet"}}
  end

  def passing?(scope, %{id: story_id}) do
    if answered?(scope),
      do: check_against_latest_run(scope, story_id),
      else: latch_stands()
  end

  @doc """
  Same as `passing?/2`, but takes the requirement graph's preloaded context.

  An unlatched story is judged from its problems alone on every graph path,
  whole or narrow, so the two compute the same verdict; whether spex has run
  at all is applied when the graph is served. For a latched story,
  `ctx.analysis_ran` says once per whole-graph pass whether spex has a
  completed run; a narrow load leaves it out, and this asks for the one story.

  `RequirementCalculator`'s delegate dispatch calls this arity whenever it
  has a context to hand it (every call inside `compute_graph/1`);
  `passing?/2` remains the fallback for a caller with none.
  """
  @spec passing?(term(), term(), map()) :: {boolean(), map()}
  # In the graph, an unlatched story is judged from the problems alone, which
  # key its cache; `RequirementGraph.serve/2` withholds its clean verdict on
  # read while no spex run has completed. Reading `analysis_ran` here would
  # store that in the cached row, and nothing revisits it.
  def passing?(scope, %{specs_ready: ready, id: story_id}, _ctx) when ready != true,
    do: unlatched(scope, story_id)

  def passing?(scope, %{id: story_id}, %{analysis_ran: ran}) when is_map(ran) do
    if Map.get(ran, "spex", false),
      do: check_against_latest_run(scope, story_id),
      else: latch_stands()
  end

  def passing?(scope, entity, _ctx), do: passing?(scope, entity)

  defp answered?(scope), do: Analysis.answered?(scope, "spex")

  # No run to argue with. The latch stands, which is the whole point of it
  # being a latch.
  defp latch_stands, do: {true, %{status: "Specs ready (no spex run to re-check against)"}}

  defp check_against_latest_run(scope, story_id) do
    case failing_own_specs(scope, story_id) do
      [] ->
        {true, %{status: "Specs ready and green on the latest spex run"}}

      problems ->
        {false,
         %{
           reason:
             "Marked specs-ready, but #{length(problems)} of this story's own specs " <>
               "fail on the latest spex run — the latch was set without them passing"
         }}
    end
  end

  # Not latched. Since e1174640 only a promote of the story latches it, and
  # the promote sits downstream of this requirement — so reading the latch
  # alone here would make the chain unsatisfiable. The latest run showing the
  # story's own specs green satisfies it; no linked specs, or a red one, does
  # not.
  defp unlatched(scope, story_id) do
    paths = own_spec_paths(scope, story_id)

    cond do
      Enum.empty?(paths) ->
        {false, %{reason: "No spec files are linked to this story"}}

      failing(scope, paths) == [] ->
        {true,
         %{
           status: "Specs green on the latest spex run (latched when promoted)",
           analysis_source: "spex"
         }}

      true ->
        {false,
         %{reason: "This story's own specs fail on the latest spex run", analysis_source: "spex"}}
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
