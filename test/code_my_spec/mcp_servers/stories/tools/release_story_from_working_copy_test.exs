defmodule CodeMySpec.McpServers.Stories.Tools.ReleaseStoryFromWorkingCopyTest do
  @moduledoc """
  3f824f74: the explicit reassign path `set_active_story` names when a story
  is held elsewhere ("Reassign it explicitly first") but nothing used to
  offer.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Stories.Tools.ReleaseStoryFromWorkingCopy
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    {:ok, main_copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, _} = CodeMySpec.Staffing.designate_main(scope, main_copy.id)

    {:ok, main} =
      AgentsRepository.create_agent(%{scope | active_working_copy_id: main_copy.id}, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-main-copy",
        role: :main,
        working_copy_id: main_copy.id
      })

    {:ok, coder} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-coder-copy",
        role: :coding,
        working_copy_id: scope.active_working_copy_id
      })

    %{scope: scope, main: main, coder: coder}
  end

  defp call(scope, params, agent) do
    {:reply, response, _frame} =
      ReleaseStoryFromWorkingCopy.execute(params, %Frame{assigns: assigns(scope, agent)})

    {response.isError, hd(Response.to_protocol(response)["content"])["text"]}
  end

  defp assigns(scope, agent), do: %{current_scope: scope, agent_id: agent.id}

  test "main frees a story held on another copy", ctx do
    story = story_fixture(ctx.scope, %{working_copy_id: ctx.scope.active_working_copy_id})

    assert {false, text} = call(ctx.scope, %{story_number: story.number}, ctx.main)
    assert text =~ "is free"
    assert Repo.get!(Story, story.id).working_copy_id == nil
  end

  test "refuses anyone other than main", ctx do
    story = story_fixture(ctx.scope, %{working_copy_id: ctx.scope.active_working_copy_id})

    assert {true, text} = call(ctx.scope, %{story_number: story.number}, ctx.coder)
    assert text =~ "Only the main agent"
    assert Repo.get!(Story, story.id).working_copy_id == ctx.scope.active_working_copy_id
  end

  test "refuses a story nobody holds", ctx do
    story = story_fixture(ctx.scope)

    assert {true, text} = call(ctx.scope, %{story_number: story.number}, ctx.main)
    assert text =~ "not held"
  end

  test "refuses the holding copy's active story without force", ctx do
    story = story_fixture(ctx.scope, %{working_copy_id: ctx.scope.active_working_copy_id})

    {:ok, _} =
      CodeMySpec.Agents.assign_team(ctx.scope, ctx.scope.active_working_copy_id, story.id)

    assert {true, text} = call(ctx.scope, %{story_number: story.number}, ctx.main)
    assert text =~ "force"
    assert Repo.get!(Story, story.id).working_copy_id == ctx.scope.active_working_copy_id

    assert {false, _text} =
             call(ctx.scope, %{story_number: story.number, force: true}, ctx.main)

    assert Repo.get!(Story, story.id).working_copy_id == nil
  end
end
