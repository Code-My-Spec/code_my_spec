defmodule CodeMySpec.WorkingCopiesActiveStoryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    # A copy is identified by {project, device, root}, so `issue/3` refuses one
    # that names no device — two boxes share a path constantly.
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    %{scope: %{scope | active_working_copy_id: copy.id}, copy: copy}
  end

  test "selecting, replacing, and clearing a story preserve the assigned backlog", %{scope: scope} do
    first = story_fixture(scope)
    second = story_fixture(scope)

    assert {:ok, %{active_story_id: first_id}} = WorkingCopies.set_active_story(scope, first.id)
    assert first_id == first.id
    assert Repo.get!(Story, first.id).working_copy_id == scope.active_working_copy_id

    assert {:ok, %{active_story_id: second_id}} = WorkingCopies.set_active_story(scope, second.id)
    assert second_id == second.id
    assert {:ok, %{active_story_id: nil}} = WorkingCopies.set_active_story(scope, nil)

    for story <- [first, second] do
      assert Repo.get!(Story, story.id).working_copy_id == scope.active_working_copy_id
    end
  end

  test "rejects parked, foreign, and differently assigned stories without replacing selection", %{
    scope: scope
  } do
    active = story_fixture(scope)
    {:ok, _} = WorkingCopies.set_active_story(scope, active.id)
    parked = story_fixture(scope, %{ready_for_dev: false})
    foreign = story_fixture(full_scope_fixture())

    {:ok, other_copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    assigned = story_fixture(scope, %{working_copy_id: other_copy.id})

    assert {:error, :story_not_ready} = WorkingCopies.set_active_story(scope, parked.id)
    assert {:error, :not_found} = WorkingCopies.set_active_story(scope, foreign.id)

    assert {:error, :story_assigned_elsewhere} =
             WorkingCopies.set_active_story(scope, assigned.id)

    assert {:ok, %{active_story_id: id}} = WorkingCopies.fetch(scope.active_working_copy_id)
    assert id == active.id
    assert Repo.get!(Story, parked.id).working_copy_id == nil
  end

  test "does not select or clear another project's working copy", %{scope: scope} do
    foreign_scope = full_scope_fixture()

    {:ok, foreign_copy} =
      WorkingCopies.issue(foreign_scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(foreign_scope)
      )

    mismatched = %{scope | active_working_copy_id: foreign_copy.id}
    assert {:error, :not_found} = WorkingCopies.set_active_story(mismatched, nil)

    assert {:error, :no_working_copy} =
             WorkingCopies.set_active_story(%{scope | active_working_copy_id: nil}, nil)
  end
end
