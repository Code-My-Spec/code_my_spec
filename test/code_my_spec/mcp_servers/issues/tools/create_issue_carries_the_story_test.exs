defmodule CodeMySpec.McpServers.Issues.Tools.CreateIssueCarriesTheStoryTest do
  @moduledoc """
  An issue filed from a story's task carries that story unless it names one.

  602c92a3 and 129e82f0 were filed by QA from story tasks and landed with no
  story, so neither gated the story it came from (518f2b52).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil, label: "qa copy", device: device_fixture(scope))

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        continuous: true,
        status: :running,
        working_copy: "/tmp/qa-files-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    story = CodeMySpec.StoriesFixtures.story_fixture(scope)
    other = CodeMySpec.StoriesFixtures.story_fixture(scope)

    {:ok, agent} =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "qa_complete",
        story_id: story.id,
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}
    %{scope: scope, story: story, other: other, frame: frame}
  end

  defp file(frame, params) do
    {:reply, response, _} =
      CreateIssue.execute(
        Map.merge(%{title: "Save does nothing", severity: "medium", description: "…"}, params),
        frame
      )

    refute response.isError, inspect(response)
    title = Map.get(params, :title, "Save does nothing")
    Enum.find(Issues.list_issues(frame.assigns.current_scope), &(&1.title == title))
  end

  test "a QA-filed app issue from a story task carries the story", ctx do
    assert file(ctx.frame, %{scope: "app"}).story_id == ctx.story.id
  end

  test "an app issue with no scope given carries the story too", ctx do
    assert file(ctx.frame, %{}).story_id == ctx.story.id
  end

  test "qa and docs findings stay off the story unless given one", ctx do
    assert file(ctx.frame, %{scope: "qa"}).story_id == nil
    assert file(ctx.frame, %{scope: "docs", title: "Docs gap"}).story_id == nil

    assert file(ctx.frame, %{scope: "qa", title: "Seeds", story_number: ctx.other.number}).story_id ==
             ctx.other.id
  end

  test "an explicit story_number still wins", ctx do
    assert file(ctx.frame, %{story_number: ctx.other.number}).story_id == ctx.other.id
  end

  test "a framework finding stays off the story", ctx do
    assert file(ctx.frame, %{scope: "framework"}).story_id == nil
  end
end
