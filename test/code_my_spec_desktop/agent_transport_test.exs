defmodule CodeMySpecDesktop.AgentTransportTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.{Agent, Transport}
  alias CodeMySpecDesktop.AgentTransport

  setup do
    keys = [:env, :desktop_agent_transport, :harness_mcp_transport, :harness_mcp_scope]
    previous = Map.new(keys, &{&1, Application.fetch_env(:code_my_spec, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:code_my_spec, key, value)
          :error -> Application.delete_env(:code_my_spec, key)
        end
      end
    end)

    scope = full_scope_fixture()
    Application.put_env(:code_my_spec, :env, :desktop)
    Application.put_env(:code_my_spec, :desktop_agent_transport, AgentTransport)
    Application.put_env(:code_my_spec, :harness_mcp_transport, CodeMySpecTest.InVmMcpTransport)
    Application.put_env(:code_my_spec, :harness_mcp_scope, scope)
    CmsHarnessTest.Machine.ensure_supervisor()

    agent =
      Repo.insert!(%Agent{
        account_id: scope.active_account_id,
        project_id: scope.active_project_id,
        execution_mode: :detached,
        engine: :alloy,
        provider: "anthropic",
        model: "claude-sonnet-5",
        role: :product,
        status: :starting,
        working_copy: Path.join(scope.cwd, "product-runtime"),
        tools: CodeMySpec.Agents.ToolSets.for_role(:product)
      })

    agent = %{agent | credential: %{"type" => "api_key", "key" => "test-no-provider-call"}}
    on_exit(fn -> AgentTransport.stop_agent(nil, agent, 1000) end)
    %{scope: scope, agent: agent}
  end

  test "detached desktop product starts a real engine without a working copy and can stop", %{
    scope: scope,
    agent: agent
  } do
    assert is_nil(agent.working_copy_id)
    assert {:ok, %{agent_id: id, pid: pid}} = Transport.start_agent(nil, agent, 5000)
    assert id == agent.id
    assert Process.alive?(pid)
    assert CodeMySpec.Agents.present?(scope, agent)
    assert is_binary(Repo.reload!(agent).mailbox_generation)
    assert {:ok, %{busy?: false}} = CmsHarness.Agents.status(id)
    assert :ok = Transport.interrupt_turn(nil, agent)
    assert :ok = Transport.stop_agent(nil, agent, 5000)
    refute Process.alive?(pid)
  end
end
