defmodule CodeMySpec.Requirements.SpecsReadyLatch do
  @moduledoc """
  A green spex run sets `specs_ready` for the stories it proves.

  `Stories.set_specs_ready/4` already says this is how the latch is meant to
  move — "the specs-passing gate sets it on a fresh green run, the chain-restart
  path clears it when the story's BDD specs are rewritten, and the user flips it
  by hand from the project UI." Two of those three existed. The only writer of
  `true` in the codebase was the UI toggle, so a story whose specs went green
  stayed `false` until somebody clicked it.

  That is the last human step in an otherwise unattended run, and it is the one
  that stopped the math project on 2026-09-22: two stories, specs written by the
  fleet, implementation written by the fleet, zero failures on a fresh run — and
  `bdd_specs_passing` false on both, because nothing set the latch.

  ## Why this can be automatic when the last attempt could not

  Both previous versions matched a failing spec to its story by parsing the spec
  directory's name, and those directories are prefixed from `story.number` in
  some places and `story.id` in others. The comparison silently matched nothing
  for whichever convention it was not written for, the gate read "this story has
  no failing specs", and it latched on red. Measured on Broken Oaths 2026-09-08:
  47 of 61 stories carried `specs_ready: true` over 127 red specs.

  `Files.bdd_spec_story_id_by_path/1` is the answer to exactly that. The linkage
  is resolved at sync time from the spec itself, so no naming convention has to
  hold — the function exists for this and carries the incident in its own doc.

  ## Only upward

  The latch is asymmetric on purpose: a green run sets it, a stale run must
  never clear it, and this only ever writes `true`. Clearing belongs to the
  paths that already do it — rewriting a story's specs, and the user.

  A story with no BDD spec files is not green, it is unmeasured, and is skipped.
  """

  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  require Logger

  @doc """
  Latch every story whose own BDD specs are green on the run just reconciled.

  Answers the ids it set, which is what the caller logs. Called after a `spex`
  run lands, against the problems that run just wrote.
  """
  @spec settle(Scope.t()) :: [integer()]
  def settle(%Scope{} = scope) do
    story_id_by_path = Files.bdd_spec_story_id_by_path(scope)

    story_id_by_path
    |> green_story_ids(failing_spec_paths(scope))
    |> latch(scope)
  end

  defp failing_spec_paths(scope) do
    scope
    |> Problems.list_project_problems(source: "spex", severity: :error)
    |> MapSet.new(& &1.file_path)
  end

  # A story is green when it has specs and none of them are among the failures.
  defp green_story_ids(story_id_by_path, failing) do
    {red, all} =
      Enum.reduce(story_id_by_path, {MapSet.new(), MapSet.new()}, fn {path, story_id},
                                                                     {red, all} ->
        {maybe_red(red, story_id, MapSet.member?(failing, path)), MapSet.put(all, story_id)}
      end)

    all |> MapSet.difference(red) |> MapSet.to_list()
  end

  defp maybe_red(red, story_id, true), do: MapSet.put(red, story_id)
  defp maybe_red(red, _story_id, false), do: red

  defp latch([], _scope), do: []

  defp latch(story_ids, scope) do
    ids = MapSet.new(story_ids)

    scope
    |> project_stories()
    |> Enum.filter(&(MapSet.member?(ids, &1.id) and &1.specs_ready != true))
    |> Enum.flat_map(&set_ready(scope, &1))
  end

  defp project_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
      _ -> []
    end
  end

  defp set_ready(scope, story) do
    case Stories.set_specs_ready(scope, story, true, at: DateTime.utc_now()) do
      {:ok, _story} ->
        Logger.info("[SpecsReadyLatch] story #{story.id} specs went green — latched")
        [story.id]

      {:error, reason} ->
        Logger.warning("[SpecsReadyLatch] could not latch story #{story.id}: #{inspect(reason)}")

        []
    end
  end
end
