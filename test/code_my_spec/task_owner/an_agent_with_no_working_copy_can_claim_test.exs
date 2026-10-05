defmodule CodeMySpec.TaskOwner.AnAgentWithNoWorkingCopyCanClaimTest do
  @moduledoc """
  An agent with no working copy is not on every checkout — it is on none.

  `TaskOwner.check_requirement_claim/2` scopes the one-claimant check to the
  agents sharing a checkout, and built that as
  `agent.working_copy_id == ^owner.working_copy_id`. Ecto will not build that
  comparison against nil: it raises `ArgumentError` ("comparing with nil is
  forbidden, use is_nil/1"), which escaped `start_task` as
  `Tool execution crashed` rather than as an ordinary refusal.

  Found live by QA on story 896, 2026-09-20. Every product-role agent on the
  QA fixture project has a null `working_copy_id`, so claiming the one
  requirement actionable there crashed all of them, and the story's whole
  task-claim-and-block family was unreachable behind it.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence

  # A row with no working copy, which is what the QA fixture project's
  # product agents actually are.
  #
  # `create_agent/2` requires `working_copy_id`, so these cannot be made
  # through it — they predate that validation. Nulled afterwards rather than
  # inserted raw, so everything else about the row is what the repository
  # would have written.
  defp copyless_agent(scope) do
    scope
    |> agent()
    |> Ecto.Changeset.change(working_copy_id: nil)
    |> Repo.update!()
  end

  defp agent(scope, attrs \\ %{}) do
    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: "product",
            status: :running,
            working_copy: "/tmp/agent-#{System.unique_integer([:positive])}",
            working_copy_id: copy.id
          },
          attrs
        )
      )

    AgentPresence.present(agent)

    agent
  end

  defp claim(scope, owner) do
    TaskOwner.add_task(scope, owner, %{
      id: Ecto.UUID.generate(),
      status: :active,
      requirement_name: "personas_complete",
      project_id: scope.active_project_id,
      started_at: DateTime.utc_now()
    })
  end

  setup do
    %{scope: full_scope_fixture()}
  end

  test "claiming a project-scoped requirement does not crash", %{scope: scope} do
    owner = copyless_agent(scope)
    assert is_nil(owner.working_copy_id), "the premise is an agent with no checkout"

    assert {:ok, %Agent{} = claimed} = claim(scope, owner),
           "an agent with no working copy could not claim project-scoped work at all"

    assert [%{requirement_name: "personas_complete", status: :active}] = claimed.tasks
  end

  test "two copyless agents on one project are still each other's neighbours", %{scope: scope} do
    {:ok, _} = claim(scope, copyless_agent(scope))

    assert {:error, :task_owned_by_another_agent} = claim(scope, copyless_agent(scope)),
           "nil matching nil is the point — two agents that name no tree share a " <>
             "claim space as much as two that name the same one"
  end

  test "an agent on a real checkout is unaffected by a copyless claimant", %{scope: scope} do
    {:ok, _} = claim(scope, copyless_agent(scope))

    assert {:ok, %Agent{}} = claim(scope, agent(scope)),
           "a claim held by an agent on no checkout withheld work from an agent " <>
             "on a real one"
  end
end
