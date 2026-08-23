defmodule CodeMySpec.Requirements.SatisfactionIsPerWorkingCopyTest do
  @moduledoc """
  A requirement's verdict belongs to the checkout that reached it.

  `Preloader.load/1` has always scoped its file query to one working copy, so
  `satisfied` has always been a statement about what one checkout could see.
  What it was not, until `20260824050000`, was *stored* that way: one row per
  (owner, name) for the whole project, so every checkout that synced overwrote
  the entire graph with its own partial view.

  Measured on this project before the fix: 177 working copies, **3 with any file
  rows at all**. Any of the other 174 computing the graph wrote
  `satisfied = false` for every file-based requirement. Stories 891, 892, 956 and
  958 all read `bdd_specs_exist = false` with
  `details: {"reason": "bdd_spec file missing"}` while three separate checkouts
  each held 10-13 of exactly those files.

  It stayed invisible because `bdd_specs_passing` is `field_true` on a story
  column rather than on files, so it stayed satisfied throughout — a story
  reading "specs are green" and "specs do not exist" at once looks like one
  story's bug rather than a systemic one.

  ## Why this goes through the rows rather than through `compute_all/1`

  The first version of this test computed the graph as each checkout and
  asserted the answers. It passed with the fix removed — because `compute_all/1`
  recomputes from that scope's own files, so it was asserting the file query,
  which was never broken, and the storage it was meant to be about never came
  into it.

  The defect lives between `upsert_all/2` and `Projection.load/2`: what gets
  written, and what a later reader gets back. So that pair is what this drives.

  Sibling of `OrphansArePerWorkingCopyTest`, one layer up: that one is about
  which checkout *has* a file, this one about whose answer gets recorded.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Requirements.{NodeRepository, Preloader, Projection, Requirement}
  alias CodeMySpec.WorkingCopies
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp verdict(story, satisfied?) do
    [
      %Requirement{
        entity_type: "story",
        entity_id: story.id,
        entity_name: story.title,
        name: "bdd_specs_exist",
        description: "BDD spec files exist for story",
        satisfied: satisfied?,
        details: %{}
      }
    ]
  end

  defp read_back(scope, story) do
    {:ok, ctx} = Preloader.load(scope)
    {nodes, _edges} = Projection.load(scope, ctx)

    nodes
    |> Enum.find(&(&1.name == "bdd_specs_exist" and &1.entity_id == story.id))
    |> case do
      nil -> :absent
      requirement -> requirement.satisfied
    end
  end

  defp two_copies(scope) do
    {:ok, has_them} = WorkingCopies.issue(scope, nil, label: "the checkout with the specs")
    {:ok, has_none} = WorkingCopies.issue(scope, nil, label: "a checkout that never scanned")

    {%{scope | active_working_copy_id: has_them.id},
     %{scope | active_working_copy_id: has_none.id}}
  end

  test "a checkout with nothing does not overwrite the verdict of one that has the files" do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{title: "A story with specs", ready_for_dev: true})
    {with_specs, without_specs} = two_copies(scope)

    NodeRepository.upsert_all(with_specs, verdict(story, true))

    assert read_back(with_specs, story) == true,
           "the premise failed: the checkout that recorded a satisfied verdict " <>
             "cannot read it back, so nothing below distinguishes an overwrite " <>
             "from a value that was never stored"

    # The empty checkout records what is true of itself. That is correct, and is
    # the whole point — its answer is about its own tree.
    NodeRepository.upsert_all(without_specs, verdict(story, false))

    assert read_back(with_specs, story) == true,
           "a checkout with no files overwrote the verdict of one that has them. " <>
             "That is the defect: 174 of this project's 177 working copies hold " <>
             "no file rows at all, so whichever synced last decided whether every " <>
             "file-based requirement on the project was satisfied."
  end

  test "and the empty checkout keeps reading its own answer, not the other's" do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{title: "Another story", ready_for_dev: true})
    {with_specs, without_specs} = two_copies(scope)

    NodeRepository.upsert_all(without_specs, verdict(story, false))
    NodeRepository.upsert_all(with_specs, verdict(story, true))

    assert read_back(without_specs, story) == false,
           "the empty checkout is now told its spec files exist because another " <>
             "checkout has them. That is the over-satisfaction `Preloader` was " <>
             "scoped to fix — 303 components whose specs lived only in another " <>
             "tree, skipped by agents that could not see them — arriving through " <>
             "the stored verdict instead of through the file query."
  end

  test "one checkout's sync does not reap another checkout's nodes" do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{title: "A third story", ready_for_dev: true})
    {first, second} = two_copies(scope)

    NodeRepository.upsert_all(first, verdict(story, true))

    # A computation that produced nothing for this story. `delete_departed`
    # reaps whatever the computation did not cover, and has to be scoped to the
    # copy — otherwise the second checkout's empty pass takes the first's rows
    # with it, which is the same overwrite arriving as a delete.
    NodeRepository.upsert_all(second, verdict(story, false))

    assert read_back(first, story) == true,
           "the second checkout's sync reaped or overwrote the first's node"
  end
end
