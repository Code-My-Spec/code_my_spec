defmodule CodeMySpec.Agents.ARetiredAgentReleasesItsTasksTest do
  @moduledoc """
  Retiring an agent left its open tasks claiming their requirements, so the
  seat's next agent was refused with `:task_owned_by_another_agent` (59c93382:
  story 1081 stalled ~2h after a Claude-to-Codex swap). Retire closes them as
  cancelled on the retired row, keeping their history.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.TaskOwner

  setup do
    scope = full_scope_fixture()
    %{scope: scope, old: agent(scope)}
  end

  defp agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :product,
        status: :running,
        working_copy: "/tmp/retire-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  defp claim(scope, owner, status \\ :active) do
    TaskOwner.add_task(scope, owner, %{
      id: Ecto.UUID.generate(),
      status: status,
      requirement_name: "story_issues_resolved",
      project_id: scope.active_project_id,
      started_at: DateTime.utc_now()
    })
  end

  test "the seat's next agent can claim what the retired one held", ctx do
    {:ok, _} = claim(ctx.scope, ctx.old)

    {:ok, _} = Agents.retire_agent(ctx.scope, ctx.old.id, reason: "codex swap")

    assert {:ok, _} = claim(ctx.scope, agent(ctx.scope))
  end

  test "its open tasks stay on its row, cancelled; finished ones are untouched", ctx do
    {:ok, with_done} = claim(ctx.scope, ctx.old, :completed)
    {:ok, _} = claim(ctx.scope, with_done)

    {:ok, _} = Agents.retire_agent(ctx.scope, ctx.old.id)

    {:ok, retired} = AgentsRepository.fetch_agent(ctx.scope, ctx.old.id)

    assert [%{status: :completed}, %{status: :cancelled, completed_at: %DateTime{}}] =
             retired.tasks
  end
end
