defmodule CodeMySpec.Agents.Tools.ARoleClaimsOnlyItsOwnWorkTest do
  @moduledoc """
  `start_task` refuses an agent a requirement its role is not offered.

  Issue a31f1cd6. Only resuming a blocked task asked whether the work was the
  caller's; a fresh claim took any requirement it was named, so an agent could
  start another role's work that nothing would ever have offered it.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Requirements
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    scope = %{scope | active_working_copy_id: copy.id}
    Requirements.recompute(scope)

    [node | _] = Requirements.actionable_for_role(scope, :product)
    %{scope: scope, node: node}
  end

  defp start_as(ctx, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: to_string(role),
        continuous: true,
        status: :running,
        working_copy: "/tmp/own-work-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: agent.id}}

    response =
      ToolLibrary.run(
        "start_task",
        %{
          entity_type: ctx.node.entity_type,
          entity_id: to_string(ctx.node.entity_id),
          requirement_name: ctx.node.name
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    {match?({:error, _}, response), elem(response, 1)}
  end

  test "another role's requirement is refused, naming whose it is", ctx do
    {error?, text} = start_as(ctx, :coding)

    assert error?, "a coding agent started product's `#{ctx.node.name}`:\n\n#{text}"
    assert text =~ ctx.node.name
    assert text =~ "product"
  end

  test "the role the requirement belongs to claims it", ctx do
    {error?, text} = start_as(ctx, :product)
    refute error?, text
  end

  # John, 2026-10-01: main is offered only its own work, but takes over a
  # stuck teammate's by hand.
  test "main may claim another role's requirement", ctx do
    {error?, text} = start_as(ctx, :main)
    refute error?, text
  end
end
