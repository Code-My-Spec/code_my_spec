defmodule CodeMySpec.Agents.ALandedStoryClosesItsPromotionTaskTest do
  @moduledoc """
  A story's promotion landing (`Promotion` emits `[:code_my_spec, :promotion,
  :team_free]` per landed story) completes the `story_promoted` task the
  requesting team still holds on it — the queue settled it, so the agent is
  not left a turn of re-completing it. Issues behave the same
  (`IssueAssignment.free/2`).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    {:ok, coder} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-copy",
        role: :coding,
        status: :running,
        working_copy_id: copy.id
      })

    %{scope: scope, copy: copy, coder: coder, story: story_fixture(scope)}
  end

  defp holding(ctx, story) do
    {:ok, coder} =
      TaskOwner.add_task(ctx.scope, ctx.coder, %{
        status: :active,
        requirement_name: "story_promoted",
        story_id: story.id
      })

    Enum.find(coder.tasks, &(&1.story_id == story.id)).id
  end

  defp landed(ctx, story) do
    :telemetry.execute([:code_my_spec, :promotion, :team_free], %{}, %{
      scope: ctx.scope,
      working_copy_id: ctx.copy.id,
      story: story
    })
  end

  defp task(ctx, id), do: TaskOwner.find_task(Repo.get!(Agent, ctx.coder.id), id)

  test "a story landing completes the requester's promote task", ctx do
    task_id = holding(ctx, ctx.story)
    landed(ctx, ctx.story)
    assert %{status: :completed} = task(ctx, task_id)
  end

  test "another story's landing leaves it open", ctx do
    task_id = holding(ctx, ctx.story)
    landed(ctx, story_fixture(ctx.scope))
    assert %{status: :active} = task(ctx, task_id)
  end
end
