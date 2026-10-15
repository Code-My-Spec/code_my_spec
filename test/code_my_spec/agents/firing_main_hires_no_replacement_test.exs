defmodule CodeMySpec.Agents.FiringMainHiresNoReplacementTest do
  @moduledoc """
  John, on criterion 2212: "Drop it. Straight get rid of the agent." And on
  main specifically (criterion 2213): "No rehire for main either" -- firing
  main hires no replacement.

  `ensure_copy_agents/3` treated a retired seat as empty and filled it
  (39af5611, `a_retired_agent_frees_its_seat_test.exs`), which is right for
  every other role: a retired coding or QA agent's seat is one staffing an
  epic or pressing "Staff it" is meant to fill again. Main is the one role
  this is wrong for now -- its seat stays empty until a person starts one
  directly, rather than coming back as a side effect of anything that calls
  `ensure_copy_agents` for its copy.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device_fixture(scope))
    {:ok, _} = WorkingCopies.designate_main(scope, copy.id)

    copy =
      copy
      |> Ecto.Changeset.change(root: "/workspace/no-rehire-#{System.unique_integer([:positive])}")
      |> CodeMySpec.Repo.update!()

    %{scope: scope, copy: copy}
  end

  defp retired(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :stopped,
        working_copy: "/tmp/no-rehire-#{System.unique_integer([:positive])}",
        working_copy_id: copy_id
      })

    {:ok, retired} =
      AgentsRepository.update_agent(scope, agent, %{retired_at: DateTime.utc_now()})

    retired
  end

  test "a retired main's seat stays empty when its copy is staffed", ctx do
    old = retired(ctx.scope, :main, ctx.copy.id)

    report = Agents.ensure_copy_agents(ctx.scope, ctx.copy, [:main])

    assert report.started == []
    assert report.failed == []
    assert report.off == []

    refute ctx.scope
           |> AgentsRepository.list_agents()
           |> Enum.any?(&(&1.role == :main and &1.id != old.id and not Agent.retired?(&1))),
           "a new main agent was started even though firing main hires no replacement"
  end

  test "a retired product's seat is still filled -- only main's lifecycle changed", ctx do
    _old = retired(ctx.scope, :product, ctx.copy.id)

    report = Agents.ensure_copy_agents(ctx.scope, ctx.copy, [:product])

    assert [%Agent{role: :product}] = report.started
  end
end
