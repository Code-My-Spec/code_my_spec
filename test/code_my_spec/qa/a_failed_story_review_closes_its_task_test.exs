defmodule CodeMySpec.Qa.AFailedStoryReviewClosesItsTaskTest do
  @moduledoc "Story QA results finish their review task; story issue submission nodes gate the next attempt."
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Qa
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        continuous: true,
        status: :running,
        working_copy: "/tmp/qa-waits-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    story =
      CodeMySpec.StoriesFixtures.story_fixture(scope)
      |> Ecto.Changeset.change(
        qa_ready_at: DateTime.utc_now(),
        qa_ready_commit: "reviewed-revision"
      )
      |> Repo.update!()

    {:ok, agent} =
      agent
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "qa_complete",
        story_id: story.id,
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    task = Enum.find(agent.tasks, &(&1.status == :active))
    {:ok, _review} = Qa.capture_story_review(scope, agent, task)

    %{scope: scope, agent: agent, story: story, task: task}
  end

  defp submit(ctx, status, issue_ids) do
    Qa.submit_qa_result(ctx.scope, %{
      task_id: ctx.task.id,
      status: status,
      scenarios: [
        %{"name" => "a scenario", "status" => to_string(status), "observation" => "what I saw"}
      ],
      issue_ids: issue_ids
    })
  end

  test "a failed story review closes its task; graph prerequisites own resumption", ctx do
    {:ok, issue} =
      CodeMySpec.Issues.create_issue(ctx.scope, %{
        title: "A broken scenario",
        description: "found while reviewing",
        severity: :high,
        scope: :app
      })

    assert {:ok, attempt} = submit(ctx, :fail, [issue.id])
    refute attempt.stale
    {:ok, agent} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
    task = Enum.find(agent.tasks, &(&1.id == ctx.task.id))
    assert task.status == :completed
    refute task.blocker_id
    refute Qa.qa_complete?(ctx.scope, ctx.story.id)
  end

  test "a result without findings is rejected without closing its task", ctx do
    assert {:error, :fail_requires_issue_ids} = submit(ctx, :fail, [])
    {:ok, agent} = AgentsRepository.fetch_agent(ctx.scope, ctx.agent.id)
    assert Enum.find(agent.tasks, &(&1.id == ctx.task.id)).status == :active
  end
end
