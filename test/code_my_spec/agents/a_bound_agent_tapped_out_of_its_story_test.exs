defmodule CodeMySpec.Agents.ABoundAgentTappedOutOfItsStoryTest do
  @moduledoc """
  Criteria 1759 and 1752 together. A task-named tap-out holds only that task,
  but a story-bound agent (`Work.bound_story_id/1`) is still offered only its
  story's work: with nothing else there it is offered nothing, never
  project-level work.
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.OfferHelpers, only: [coding_work_waiting: 1, next_task: 2, agent_frame: 2]
  import CodeMySpecSpex.StoryBoundHelpers, only: [issue_accepted: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    :ok = Fixtures.install_recording_agent_transport()
    ctx = ctx |> coding_work_waiting() |> issue_accepted()
    coder = Fixtures.running_agent(ctx.scope, role: "coding", continuous: true)
    Map.merge(ctx, %{coder: coder.id, frame: agent_frame(ctx, coder.id)})
  end

  # Instrument check: before the claim, the story's work is what is offered.
  test "unbound, it is offered its copy's story work", ctx do
    assert next(ctx) =~ "requirement_name=`ready_for_qa`"
  end

  test "bound, tapped out of its only story task: offered nothing, no project work", ctx do
    task = next_task(ctx, ctx.coder)
    assert task.entity_type == "story"
    {:reply, started, _} = StartTask.execute(task, ctx.frame)
    refute started.isError, response_text(started)

    {:reply, tapped, _} =
      TapOut.execute(%{task_id: extract_task_id!(started), reason: "Contradicts"}, ctx.frame)

    refute tapped.isError, response_text(tapped)

    coder = Repo.get!(Agent, ctx.coder)
    assert Work.bound_story_id(coder)
    assert Work.claimable_work(ctx.scope, coder) == []
    assert {:ok, :not_runnable} = Work.request_turn_if_runnable(ctx.scope, coder, :test)
    refute next(ctx) =~ "issues_resolved"
  end

  defp next(ctx) do
    {:reply, response, _} = GetNextRequirement.execute(%{}, ctx.frame)
    response_text(response)
  end
end
