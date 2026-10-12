defmodule CodeMySpec.Agents.AssignmentMoveStoryTest do
  @moduledoc """
  Moving one story to another working copy (ae4e748f): `EpicDispatch.place/3`
  moves a whole epic at once, `Stories.reserve_story/3` only claims an unassigned
  story, and `offboard/2` releases everything a copy holds. `Assignment.move_story/4` is
  the one-story counterpart those three leave out.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    source = a_copy(scope)
    target = a_copy(scope)
    {:ok, target} = WorkingCopies.report_root(target, "/tmp/a-target-checkout")

    %{scope: scope, source: source, target: target}
  end

  defp a_copy(scope) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope))

    copy
  end

  test "moves a story onto a target that has a checkout", %{
    scope: scope,
    source: source,
    target: target
  } do
    story = story_fixture(scope, %{working_copy_id: source.id})

    assert {:ok, moved} = Assignment.move_story(scope, story.id, target.id)
    assert moved.working_copy_id == target.id
    assert Repo.get!(Story, story.id).working_copy_id == target.id
  end

  test "moves a story that was unassigned", %{scope: scope, target: target} do
    story = story_fixture(scope)

    assert {:ok, moved} = Assignment.move_story(scope, story.id, target.id)
    assert moved.working_copy_id == target.id
  end

  test "refuses onto a target with no checkout on disk", %{scope: scope, source: source} do
    rootless = a_copy(scope)
    story = story_fixture(scope, %{working_copy_id: source.id})

    assert {:error, :no_checkout} = Assignment.move_story(scope, story.id, rootless.id)
    assert Repo.get!(Story, story.id).working_copy_id == source.id
  end

  test "refuses to take the source copy's active story without force", %{
    scope: scope,
    source: source,
    target: target
  } do
    story = story_fixture(scope, %{working_copy_id: source.id})

    source_scope = %{scope | active_working_copy_id: source.id}

    {:ok, _coding} =
      AgentsRepository.create_agent(source_scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: :coding,
        working_copy_id: source.id
      })

    {:ok, _} = Agents.assign_team(source_scope, source.id, story.id)
    assert WorkingCopies.team_story_id(source.id) == story.id

    assert {:error, :story_active_elsewhere} = Assignment.move_story(scope, story.id, target.id)
    assert Repo.get!(Story, story.id).working_copy_id == source.id

    assert {:ok, moved} = Assignment.move_story(scope, story.id, target.id, force: true)
    assert moved.working_copy_id == target.id
  end

  test "does not find a story outside this project", %{scope: scope, target: target} do
    foreign = story_fixture(full_scope_fixture())

    assert {:error, :not_found} = Assignment.move_story(scope, foreign.id, target.id)
  end

  test "does not find a target copy outside this project", %{scope: scope, source: source} do
    foreign_scope = full_scope_fixture()
    foreign_target = a_copy(foreign_scope)
    {:ok, foreign_target} = WorkingCopies.report_root(foreign_target, "/tmp/a-foreign-checkout")

    story = story_fixture(scope, %{working_copy_id: source.id})

    assert {:error, :not_found} = Assignment.move_story(scope, story.id, foreign_target.id)
  end
end
