defmodule CodeMySpec.Stories.Tools.AStoryHeldElsewhereNamesItsCopyTest do
  @moduledoc """
  Selecting a story another copy holds says which copy, and how to free it.

  The refusal named neither: main handed story 1046 to team 2, was refused,
  and asked John which copy held it because its tools did not say
  (2026-10-12).
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  test "the refusal names the holding copy and the tool that frees it" do
    scope = full_scope_fixture()

    {:ok, holder} =
      WorkingCopies.issue(scope, nil, label: "devops-q", device: device_fixture(scope))

    {:ok, team} = WorkingCopies.issue(scope, nil, label: "team 2", device: device_fixture(scope))

    story = story_fixture(scope, %{ready_for_dev: true})
    {:ok, story} = Stories.update_story(scope, story, %{working_copy_id: holder.id})

    {:ok, _} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :coding,
        status: :running,
        working_copy: "/tmp/held-elsewhere",
        working_copy_id: team.id
      })

    frame = %Frame{assigns: %{current_scope: %{scope | active_working_copy_id: team.id}}}

    response =
      ToolLibrary.run(
        "set_active_story",
        %{story_number: story.number},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert {:error, text} = response
    assert text =~ "devops-q"
    assert text =~ holder.id
    assert text =~ "release_story_from_working_copy"
  end
end
