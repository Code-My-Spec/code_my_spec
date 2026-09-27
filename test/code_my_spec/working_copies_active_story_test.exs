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

  # A copy used to keep every story it had ever been pointed at, and each one
  # was then stuck: `story_assigned_elsewhere` refuses to move an assigned
  # story, and clearing left the assignment behind. Pointing a copy at a second
  # story stranded the first with no tool able to free it.
  test "a copy holds the story it is pointed at and releases the rest", %{scope: scope} do
    first = story_fixture(scope)
    second = story_fixture(scope)

    assert {:ok, %{active_story_id: first_id}} = WorkingCopies.set_active_story(scope, first.id)
    assert first_id == first.id
    assert Repo.get!(Story, first.id).working_copy_id == scope.active_working_copy_id

    assert {:ok, %{active_story_id: second_id}} = WorkingCopies.set_active_story(scope, second.id)
    assert second_id == second.id

    assert Repo.get!(Story, second.id).working_copy_id == scope.active_working_copy_id

    assert Repo.get!(Story, first.id).working_copy_id == nil,
           "the story it moved off has to be free for another copy to take"

    assert {:ok, %{active_story_id: nil}} = WorkingCopies.set_active_story(scope, nil)

    for story <- [first, second] do
      assert Repo.get!(Story, story.id).working_copy_id == nil,
             "clearing releases what the copy held rather than pinning it there"
    end
  end

  # The release happens inside the same transaction as the selection, so a
  # refusal takes it back: a copy pointed at something invalid keeps what it
  # had rather than being emptied by the attempt.
  test "a refused selection leaves the held story where it was", %{scope: scope} do
    held = story_fixture(scope)
    {:ok, _} = WorkingCopies.set_active_story(scope, held.id)

    parked = story_fixture(scope, %{ready_for_dev: false})

    assert {:error, :story_not_ready} = WorkingCopies.set_active_story(scope, parked.id)

    assert Repo.get!(Story, held.id).working_copy_id == scope.active_working_copy_id
    assert {:ok, %{active_story_id: id}} = WorkingCopies.fetch(scope.active_working_copy_id)
    assert id == held.id
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
