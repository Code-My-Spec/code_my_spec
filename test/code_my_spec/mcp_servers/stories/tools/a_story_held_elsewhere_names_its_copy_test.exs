defmodule CodeMySpec.McpServers.Stories.Tools.AStoryHeldElsewhereNamesItsCopyTest do
  @moduledoc """
  Selecting a story another copy holds says which copy, and how to free it.

  The refusal named neither: main handed story 1046 to team 2, was refused,
  and asked John which copy held it because its tools did not say
  (2026-10-12).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
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

    {:reply, response, ^frame} = SetActiveStory.execute(%{story_number: story.number}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"]
    text = hd(protocol["content"])["text"]
    assert text =~ "devops-q"
    assert text =~ holder.id
    assert text =~ "unassign_story_from_working_copy"
  end
end
