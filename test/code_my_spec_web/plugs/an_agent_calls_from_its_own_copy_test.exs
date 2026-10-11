defmodule CodeMySpecWeb.Plugs.AnAgentCallsFromItsOwnCopyTest do
  @moduledoc """
  ed28189c: a call naming an agent and no harness over the hosted
  `/mcp/harness` had a project and no working copy, so every file-touching tool
  refused it with `:no_environment` — though the agent named has a copy. Which
  copy is part of who is calling (John). A named harness still stands; a
  disagreement is logged.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Environments.Environment
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecWeb.Plugs.AgentScope

  defp call(scope, agent) do
    :post
    |> Phoenix.ConnTest.build_conn("/mcp/harness", "")
    |> Plug.Conn.assign(:current_scope, scope)
    |> Plug.Conn.put_req_header("x-agent-id", agent.id)
    |> AgentScope.call([])
  end

  defp agent_for(scope, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        role: "coding",
        working_copy: "/tmp/agent-own-copy",
        working_copy_id: copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    AgentPresence.present(agent)

    agent
  end

  test "an agent named with no harness selects its own copy for environment resolution" do
    scope = working_copy_scope_fixture()
    copy_id = scope.active_working_copy_id
    agent = agent_for(scope, copy_id)

    conn = call(%{scope | active_working_copy_id: nil}, agent)

    assert conn.assigns.agent_id == agent.id
    assert conn.assigns.current_scope.active_working_copy_id == copy_id

    assert %Environment{} = CodeMySpec.WorkingCopies.environment(conn.assigns.current_scope),
           "the agent's rooted copy must resolve its own execution environment"
  end

  test "a named harness that is not the agent's stands, and the disagreement is logged" do
    scope = full_scope_fixture()
    agent = agent_for(scope, scope.active_working_copy_id)
    named = Ecto.UUID.generate()

    log =
      capture_log([level: :warning], fn ->
        conn = call(%{scope | active_working_copy_id: named}, agent)
        assert conn.assigns.current_scope.active_working_copy_id == named
      end)

    assert log =~ "naming working copy #{named}"
  end
end
