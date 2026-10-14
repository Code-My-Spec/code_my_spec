defmodule CodeMySpec.Requirements.NarrowBddCoverageTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.{Preloader, RequirementGraph, ShadowProjector}
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.WorkingCopies

  setup do
    :ok
  end

  test "criterion updates cannot borrow specs from another checkout for the project view" do
    scope = full_scope_fixture()

    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{
        default_working_copy_id: scope.active_working_copy_id
      })

    scope = %{scope | active_project: project}
    {:ok, other} = WorkingCopies.issue(scope, nil, label: "Other", device: device_fixture(scope))
    story = story_fixture(scope, %{ready_for_dev: true, criteria: []})
    criterion = criterion_fixture(scope, story)

    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: other.id,
      story_id: story.id,
      criterion_number: criterion.number,
      path: "test/spex/elsewhere.exs",
      role: :bdd_spec,
      valid: true
    })

    ui_scope = %{scope | active_working_copy_id: nil}
    {:ok, narrow} = Preloader.load_story(ui_scope, story.id)

    {_, nodes} =
      RequirementGraph.compute_entity(
        ui_scope,
        narrow,
        Configurations.get_or_create(scope),
        {"story", story.id}
      )

    refute Enum.find(nodes, &(&1.name == "bdd_specs_exist")).satisfied

    {:ok, _} = ShadowProjector.ensure_projecting(scope)

    :ok =
      ShadowProjector.settle(scope.active_project_id, [
        nil,
        scope.active_working_copy_id,
        other.id
      ])

    {:ok, _} =
      AcceptanceCriteria.update_criterion(scope, criterion, %{description: "Revised criterion"})

    :ok =
      ShadowProjector.settle(scope.active_project_id, [
        nil,
        scope.active_working_copy_id,
        other.id
      ])

    report = Requirements.served_vs_recomputed(ui_scope)
    assert report.disagree == 0
    assert report.actionable_disagree == 0
  end
end
