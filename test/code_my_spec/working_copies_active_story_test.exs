defmodule CodeMySpec.WorkingCopiesActiveStoryTest do
  @moduledoc """
  Selecting a copy's story: since a31f1cd6 it goes to the copy's team, through
  `Agents.assign_team/3`, and the copy records none of its own. The
  reservation rules (`Stories.reserve_story/3`) are what this holds.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import Ecto.Query
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    # A copy is identified by {project, device, root}, so `issue/3` refuses one
    # that names no device — two boxes share a path constantly.
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    scope = %{scope | active_working_copy_id: copy.id}

    {:ok, _coding} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: :coding,
        working_copy_id: copy.id
      })

    %{scope: scope, copy: copy}
  end

  defp choose(scope, story_id),
    do: Agents.assign_team(scope, scope.active_working_copy_id, story_id)

  # Every requirement of the story satisfied at the copy: its own rows, and the
  # ones stored once per project.
  defp satisfy_story(story, scope) do
    Repo.update_all(
      from(n in CodeMySpec.Requirements.Node,
        where: n.story_id == ^story.id and n.working_copy_id == ^scope.active_working_copy_id
      ),
      set: [satisfied: true]
    )

    Repo.update_all(
      from(n in {"project_requirements", CodeMySpec.Requirements.Node},
        where: n.story_id == ^story.id
      ),
      set: [satisfied: true]
    )
  end

  # A copy used to keep every story it had ever been pointed at, and each one
  # was then stuck: `story_assigned_elsewhere` refuses to move an assigned
  # story, and clearing left the assignment behind. Pointing a copy at a second
  # story stranded the first with no tool able to free it.
  test "a copy holds the story it is pointed at and releases the one it left", %{scope: scope} do
    first = story_fixture(scope)
    second = story_fixture(scope)

    assert {:ok, first_id} = choose(scope, first.id)
    assert first_id == first.id
    assert Repo.get!(Story, first.id).working_copy_id == scope.active_working_copy_id

    assert {:ok, second_id} = choose(scope, second.id)
    assert second_id == second.id
    assert WorkingCopies.team_story_id(scope.active_working_copy_id) == second.id

    assert Repo.get!(Story, second.id).working_copy_id == scope.active_working_copy_id

    assert Repo.get!(Story, first.id).working_copy_id == nil,
           "the story it moved off has to be free for another copy to take"

    assert {:ok, nil} = choose(scope, nil)

    for story <- [first, second] do
      assert Repo.get!(Story, story.id).working_copy_id == nil,
             "clearing releases what the team held rather than pinning it there"
    end
  end

  # A refusal rolls back with the selection: a team pointed at something invalid
  # keeps what it had rather than being emptied by the attempt.
  test "a refused selection leaves the held story where it was", %{scope: scope} do
    held = story_fixture(scope)
    {:ok, _} = choose(scope, held.id)

    parked = story_fixture(scope, %{ready_for_dev: false})

    assert {:error, :story_not_ready} = choose(scope, parked.id)

    assert Repo.get!(Story, held.id).working_copy_id == scope.active_working_copy_id
    assert WorkingCopies.team_story_id(scope.active_working_copy_id) == held.id
  end

  # Story 811 was handed to team 3 with every requirement already satisfied;
  # nothing could land for it, so no team-free notice reached main and the team
  # sat idle (2026-10-15).
  test "a promoted story with every requirement satisfied at the copy is refused", %{scope: scope} do
    held = story_fixture(scope)
    {:ok, _} = choose(scope, held.id)
    done = story_fixture(scope)
    {:ok, done} = done |> Story.changeset(%{promoted_version: "2.0.1"}) |> Repo.update()

    {_done, total} = CodeMySpec.Requirements.story_progress(scope, done.id)

    satisfy_story(done, scope)

    assert {^total, ^total} = CodeMySpec.Requirements.story_progress(scope, done.id),
           "the fixture did not make a fully satisfied story"

    assert {:error, :story_done} = choose(scope, done.id)
    assert WorkingCopies.team_story_id(scope.active_working_copy_id) == held.id
  end

  # Metric Flow's coder fixed five issues on promoted stories; each needed its
  # story held to go to QA, and the refusal above left them stranded (2026-10-15).
  test "a promoted, satisfied story with an accepted issue can still be taken", %{scope: scope} do
    {:ok, done} =
      story_fixture(scope) |> Story.changeset(%{promoted_version: "2.0.1"}) |> Repo.update()

    satisfy_story(done, scope)

    issue_fixture(scope, %{story_id: done.id, status: :accepted})

    assert {:ok, _} = choose(scope, done.id)
    assert WorkingCopies.team_story_id(scope.active_working_copy_id) == done.id
  end

  test "rejects parked, foreign, and differently assigned stories without replacing selection", %{
    scope: scope
  } do
    active = story_fixture(scope)
    {:ok, _} = choose(scope, active.id)
    parked = story_fixture(scope, %{ready_for_dev: false})
    foreign = story_fixture(full_scope_fixture())

    {:ok, other_copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    assigned = story_fixture(scope, %{working_copy_id: other_copy.id})

    assert {:error, :story_not_ready} = choose(scope, parked.id)
    assert {:error, :not_found} = choose(scope, foreign.id)
    assert {:error, :story_assigned_elsewhere} = choose(scope, assigned.id)

    assert WorkingCopies.team_story_id(scope.active_working_copy_id) == active.id
    assert Repo.get!(Story, parked.id).working_copy_id == nil
  end

  test "does not select for another project's working copy", %{scope: scope} do
    foreign_scope = full_scope_fixture()

    {:ok, foreign_copy} =
      WorkingCopies.issue(foreign_scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(foreign_scope)
      )

    assert {:error, :not_found} = Agents.assign_team(scope, foreign_copy.id, nil)
    assert {:error, :no_working_copy} = Agents.assign_team(scope, nil, nil)
  end
end
