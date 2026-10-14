defmodule CodeMySpec.Requirements.EventProjectionMembershipTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.{GraphStore, IncrementalGraph, Node, Preloader, RequirementGraph}
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  setup do
    %{scope: full_scope_fixture()}
  end

  test "an unassigned story gains nodes and edges in the checkout it enters", %{scope: scope} do
    {:ok, other} = WorkingCopies.issue(scope, nil, label: "Other", device: device_fixture(scope))
    story = story_fixture(scope, %{ready_for_dev: true, working_copy_id: other.id})
    {:ok, _} = IncrementalGraph.ensure_projecting(scope)

    :ok =
      IncrementalGraph.settle(scope.active_project_id, [
        scope.active_working_copy_id,
        other.id,
        nil
      ])

    assert story_names(scope, story) == []

    {:ok, _} = Stories.update_story(scope, story, %{working_copy_id: nil})
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])

    assert "bdd_specs_exist" in story_names(scope, story)
    report = Requirements.served_vs_recomputed(scope)
    assert report.missing == 0
    assert report.edges_missing == 0
    assert report.edges_extra == 0
  end

  test "a complete story cannot conceal another story's missing nodes", %{scope: scope} do
    story_fixture(scope, %{ready_for_dev: true})
    missing = story_fixture(scope, %{ready_for_dev: true})
    {:ok, _} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id, [scope.active_working_copy_id])

    defined =
      RequirementGraph.defined_names(Preloader.topology_context(scope), Configurations.get(scope))

    assert GraphStore.definitions_covered?(scope, defined)

    Repo.delete_all(
      from n in Node,
        where: n.story_id == ^missing.id and n.working_copy_id == ^scope.active_working_copy_id
    )

    refute GraphStore.definitions_covered?(scope, defined)

    assert MapSet.member?(
             GraphStore.incomplete_entities(scope, defined.entities),
             {"story", missing.id}
           )
  end

  defp story_names(scope, story) do
    Repo.all(
      from n in Node,
        where: n.story_id == ^story.id and n.working_copy_id == ^scope.active_working_copy_id,
        select: n.name
    )
  end
end
