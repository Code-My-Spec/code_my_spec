defmodule CodeMySpec.Agents.OneAgentPerRoleOnACopyTest do
  @moduledoc """
  A working copy holds one running agent per role.

  On metric_flow 2026-09-27 the main agent could not reach `restart_agent`, so
  it called `start_agent` for a fresh coder on a copy that already had one.
  Once the original was restarted the copy had two coding agents claiming and
  editing the same work.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a staffed checkout",
        device: device_fixture(scope)
      )

    copy =
      copy
      |> Ecto.Changeset.change(root: "/workspace/per-role-#{System.unique_integer([:positive])}")
      |> CodeMySpec.Repo.update!()

    {:ok, coder} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: copy.root,
        working_copy_id: copy.id
      })

    AgentPresence.present(coder)

    %{scope: scope, copy: copy, coder: coder}
  end

  defp start(ctx, role),
    do:
      Agents.start_agent(ctx.scope, %{
        role: role,
        provider: "anthropic",
        working_copy_id: ctx.copy.id
      })

  test "a second agent of a running role is refused, naming the one there", ctx do
    coder_id = ctx.coder.id

    assert {:error, {:role_taken, :coding, ^coder_id, _root}} = start(ctx, "coding")
  end

  test "the refusal tells the caller to restart or message the existing agent", ctx do
    {:error, reason} = start(ctx, "coding")

    %Response{content: [%{"text" => text}]} = AgentsMapper.error(reason, "anthropic")

    assert text =~ ctx.coder.id
    assert text =~ "restart_agent"
    assert text =~ "message_agent"
  end

  test "another role still starts on the same copy", ctx do
    assert {:ok, qa} = start(ctx, "qa")
    assert qa.role == :qa
  end

  test "restarting the existing agent is not refused as its own duplicate", ctx do
    assert {:ok, restarted} = Agents.restart_agent(ctx.scope, ctx.coder.id)
    assert restarted.id == ctx.coder.id
  end

  test "staffing the copy fills the missing roles and leaves the running one", ctx do
    staffed = Agents.ensure_copy_agents(ctx.scope, ctx.copy)

    assert staffed.failed == []
    assert Enum.map(staffed.started, & &1.role) == [:qa]
  end
end
