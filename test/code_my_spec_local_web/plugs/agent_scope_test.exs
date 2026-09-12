defmodule CodeMySpecLocalWeb.Plugs.AgentScopeTest do
  @moduledoc """
  That the local endpoint knows which agent is calling it.

  It did not, and nothing said so. The hosted `:mcp_protected` pipeline carried
  `AgentScope`; the local `:mcp` pipeline — the one every locally-run agent
  actually calls — carried `LocalOnly` and `HarnessScope` and stopped there.

  The symptom was silent on both sides. `ask_user_question` fell back to
  `holder: "user"` with a NULL `agent_id`, so every question a local agent asked
  went straight to the person, and `QuestionsRepository` inner-joins on
  `agent_id`, so the main agent could not see those rows even to intercept them.
  The user assumed the main agent had judged the question worth escalating; the
  main agent saw an empty list and assumed nobody was blocked.

  QA of story 1016 found it by driving the real endpoint and reading the row.
  No test existed to find it, which is why one exists now.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpecLocalWeb.Plugs.AgentScope

  defp scoped_conn(scope) do
    :get
    |> Phoenix.ConnTest.build_conn("/mcp", "")
    |> Plug.Conn.assign(:current_scope, scope)
  end

  # Through the repository rather than `start_agent/2`: this is about the plug
  # resolving an agent that exists, not about the lifecycle that mints one, and
  # starting one needs a provider credential this test has no business carrying.
  defp agent_for(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        role: "coding",
        working_copy: "/tmp/agent-scope-test",
        working_copy_id: scope.active_working_copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    agent
  end

  test "an agent named in X-Agent-Id is put on the conn" do
    scope = full_scope_fixture()
    agent = agent_for(scope)

    conn =
      scope
      |> scoped_conn()
      |> Plug.Conn.put_req_header("x-agent-id", agent.id)
      |> AgentScope.call([])

    assert conn.assigns[:agent_id] == agent.id,
           """
           The local endpoint does not learn who is calling.

           Everything that routes a question to the main agent rather than to
           the person hangs off this assign. Without it `ask_user_question`
           writes holder "user" and a NULL agent_id, which is both the wrong
           destination and an unreachable row.
           """
  end

  test "no header means no agent, and the call still goes through" do
    scope = full_scope_fixture()

    conn = scope |> scoped_conn() |> AgentScope.call([])

    refute conn.assigns[:agent_id]
    refute conn.halted, "a call that names no agent is a call without an agent, not a refusal"
  end

  test "an agent belonging to another project is dropped" do
    mine = full_scope_fixture()
    theirs = full_scope_fixture()
    other_agent = agent_for(theirs)

    conn =
      mine
      |> scoped_conn()
      |> Plug.Conn.put_req_header("x-agent-id", other_agent.id)
      |> AgentScope.call([])

    refute conn.assigns[:agent_id],
           """
           A header naming another project's agent was honoured.

           The header is a claim, not proof — this pipeline authenticates the
           caller, not the agent. Honouring it would let one harness act as
           another's.
           """
  end
end
