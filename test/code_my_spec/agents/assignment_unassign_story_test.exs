defmodule CodeMySpec.Agents.AssignmentUnassignStoryTest do
  @moduledoc """
  3f824f74: freeing a story from whatever working copy holds it, with
  nowhere new to go yet -- the explicit reassign path a `set_active_story`
  refusal names ("Reassign it explicitly first") but nothing used to offer.
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
    holder = a_copy(scope)
    %{scope: scope, holder: holder}
  end

  defp a_copy(scope) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    copy
  end

  test "frees a story reserved to a copy with no live team", %{scope: scope, holder: holder} do
    story = story_fixture(scope, %{working_copy_id: holder.id})

    assert {:ok, freed} = Assignment.unassign_story(scope, story.id)
    assert freed.working_copy_id == nil
    assert Repo.get!(Story, story.id).working_copy_id == nil
  end

  test "refuses a story nobody holds", %{scope: scope} do
    story = story_fixture(scope)

    assert {:error, :not_assigned} = Assignment.unassign_story(scope, story.id)
  end

  test "refuses the holding copy's active story without force", %{scope: scope, holder: holder} do
    story = story_fixture(scope, %{working_copy_id: holder.id})
    holder_scope = %{scope | active_working_copy_id: holder.id}

    {:ok, _coding} =
      AgentsRepository.create_agent(holder_scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: :coding,
        working_copy_id: holder.id
      })

    {:ok, _} = Agents.assign_team(holder_scope, holder.id, story.id)
    assert WorkingCopies.team_story_id(holder.id) == story.id

    assert {:error, :story_active_elsewhere} = Assignment.unassign_story(scope, story.id)
    assert Repo.get!(Story, story.id).working_copy_id == holder.id

    assert {:ok, freed} = Assignment.unassign_story(scope, story.id, force: true)
    assert freed.working_copy_id == nil
  end

  test "does not find a story outside this project", %{scope: scope} do
    foreign = story_fixture(full_scope_fixture())

    assert {:error, :not_found} = Assignment.unassign_story(scope, foreign.id)
  end
end
