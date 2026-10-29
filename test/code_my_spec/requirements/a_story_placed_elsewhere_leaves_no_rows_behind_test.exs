defmodule CodeMySpec.Requirements.AStoryPlacedElsewhereLeavesNoRowsBehindTest do
  @moduledoc """
  A story placed at one checkout leaves no rows at the others.

  Its rows were written while it was unplaced, at every checkout. Placed, it is
  no longer an entity the other checkouts see, so coverage read its rows there
  as ones the vantage should not hold and reseeded it; the seed covered only
  the stories it sees and never reaped them. Every projector arrival reseeded
  nearly every vantage of the largest project.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Configurations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{GraphStore, IncrementalGraph, Preloader, RequirementGraph}
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies

  test "a seed at the other checkout reaps the placed story's rows, and the next arrival trusts it" do
    here = full_scope_fixture()
    {:ok, there} = WorkingCopies.issue(here, nil, label: "There", device: device_fixture(here))
    story = story_fixture(here, %{ready_for_dev: true})

    {:ok, _pid} = IncrementalGraph.ensure_projecting(here)
    :ok = IncrementalGraph.settle(here.active_project_id, [here.active_working_copy_id, there.id])
    assert rows_here(here, story) > 0, "the premise did not hold: no rows for the story here"

    Repo.update_all(from(s in Story, where: s.id == ^story.id), set: [working_copy_id: there.id])
    refute covered?(here), "the premise did not hold: the stale rows did not unsettle coverage"

    restart_projector(here)

    assert rows_here(here, story) == 0,
           "a story placed at another checkout kept its rows here after this checkout's seed"

    assert covered?(here),
           "this checkout still reads as uncovered, so every arrival reseeds it"
  end

  defp rows_here(scope, story) do
    Repo.aggregate(
      from(n in "requirements",
        where: n.story_id == ^story.id,
        where: n.working_copy_id == type(^scope.active_working_copy_id, :binary_id)
      ),
      :count
    )
  end

  defp covered?(scope) do
    config = Configurations.get_or_create(scope)
    defined = RequirementGraph.defined_names(Preloader.topology_context(scope), config)
    GraphStore.definitions_covered?(scope, defined)
  end

  defp restart_projector(scope) do
    pid = GenServer.whereis(IncrementalGraph.via(scope.active_project_id))
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    {:ok, fresh} = IncrementalGraph.ensure_projecting(scope)
    refute fresh == pid, "the projector did not go away, so nothing arrived"
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])
  end
end
