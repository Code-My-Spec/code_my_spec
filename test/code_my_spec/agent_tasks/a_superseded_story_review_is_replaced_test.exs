defmodule CodeMySpec.AgentTasks.ASupersededStoryReviewIsReplacedTest do
  use CodeMySpecSpex.Case, async: false

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Qa
  alias CodeMySpec.Stories
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    context = context |> FullSatisfactionFixtures.apply_without_qa_story() |> Slice.activate()
    agents = Agents.list_agents(context.scope)
    coding = Enum.find(agents, &(&1.role == :coding))
    qa = Enum.find(agents, &(&1.role == :qa))

    task = %{
      id: Ecto.UUID.generate(),
      requirement_name: "qa_complete",
      status: :active,
      session_type: QaStory,
      story_id: context.story.id,
      project_id: context.scope.active_project_id
    }

    {:ok, qa} = TaskOwner.add_task(context.scope, qa, task)
    {:ok, _} = Qa.capture_story_review(context.scope, qa, task)
    Map.merge(context, %{coding: coding, qa: qa, old_task: task})
  end

  defp start(context) do
    :ok = Fixtures.settle_graph(context.scope)

    params = %{
      requirement_name: "qa_complete",
      entity_type: "story",
      entity_id: to_string(context.story.number)
    }

    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.qa.id}}
    {:reply, result, _} = StartTask.execute(params, frame)
    result
  end

  test "healthy review retains its task; changed submission cancels it until recertification",
       context do
    refute start(context).isError
    {:ok, before} = Agents.fetch_agent(context.scope, context.qa.id)
    assert TaskOwner.active_task(before).id == context.old_task.id

    issue =
      Fixtures.issue_fixture(context.scope, %{
        story_id: context.story.id,
        status: :accepted,
        severity: :high
      })

    {:ok, _} =
      Issues.submit_story_issue(context.scope, issue, %{revision: "new-fix", evidence: "tested"})

    assert start(context).isError
    {:ok, blocked} = Agents.fetch_agent(context.scope, context.qa.id)
    assert TaskOwner.find_task(blocked, context.old_task.id).status == :cancelled
    assert TaskOwner.active_task(blocked) == nil

    story = Stories.get_story!(context.scope, context.story.id)
    {:ok, _} = Stories.set_qa_ready(context.scope, story, "new-fix")
    refute start(context).isError
    {:ok, restarted} = Agents.fetch_agent(context.scope, context.qa.id)
    refute TaskOwner.active_task(restarted).id == context.old_task.id
  end
end
