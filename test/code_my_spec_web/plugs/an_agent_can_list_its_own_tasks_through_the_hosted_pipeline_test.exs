defmodule CodeMySpecWeb.Plugs.AnAgentCanListItsOwnTasksThroughTheHostedPipelineTest do
  @moduledoc """
  27599aa1: QA drove a raw authenticated POST to the hosted `/mcp/harness`
  with a standing fixture `X-Agent-Id` and got `list_tasks`'s refusal back --
  "No session_id and no agent id on this call, so there is no owner whose
  tasks to list." Product's own correction: the question that decides the fix
  is whether the hosted pipeline honours a supplied agent identity for this
  surface at all, or should not be driven this way from a client call.

  It already does. `AgentScope` (criterion 1773, ed28189c) resolves
  `X-Agent-Id` into `conn.assigns[:agent_id]` and `:current_scope`, scoped to
  the project the request is already authenticated into; Anubis's own
  transport hands `conn.assigns` straight into the `Frame` every tool
  receives (`deps/anubis_mcp/.../streamable_http/plug.ex`,
  `build_request_context/2`); and `list_tasks` reads exactly that
  (`Map.get(params, :agent_id) || frame.assigns[:agent_id]`). This test
  chains the real pipeline pieces together the way `/mcp/harness` actually
  runs them, the same way criterion 1773's own spex does for a file-writing
  tool, to prove a supplied agent identity reaches `list_tasks` and resolves
  an owner rather than erroring.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpecWeb.Plugs.AgentScope

  defp hosted_list_tasks(scope, agent) do
    conn =
      :post
      |> Phoenix.ConnTest.build_conn("/mcp/harness", "")
      |> Plug.Conn.assign(:current_scope, scope)
      |> Plug.Conn.put_req_header("x-agent-id", agent.id)
      |> AgentScope.call([])

    {:reply, reply, _frame} = ListTasks.execute(%{}, %Frame{assigns: conn.assigns})

    response_text(reply)
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)

  defp agent_for(scope, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        role: "coding",
        working_copy: "/tmp/agent-own-tasks",
        working_copy_id: copy_id,
        project_id: scope.active_project_id,
        account_id: scope.active_account_id,
        status: :running
      })

    agent
  end

  test "a call naming only X-Agent-Id resolves an owner for list_tasks, not a session fault" do
    scope = full_scope_fixture()
    agent = agent_for(scope, scope.active_working_copy_id)

    text = hosted_list_tasks(scope, agent)

    refute text =~ "No session_id and no agent id",
           "a supplied X-Agent-Id should resolve an owner for list_tasks through the " <>
             "real hosted pipeline, not fall through to the no-identity refusal. Got: #{text}"

    assert text == "No tasks.",
           "a freshly-created agent with no tasks should read as that, confirming the " <>
             "owner resolved was this agent and not some other fallback. Got: #{text}"
  end

  test "an agent id belonging to another project never resolves an owner here" do
    scope = full_scope_fixture()
    other = full_scope_fixture()
    foreign_agent = agent_for(other, other.active_working_copy_id)

    text = hosted_list_tasks(scope, foreign_agent)

    assert text =~ "No session_id and no agent id",
           "a foreign project's agent id must not resolve an owner on this project's " <>
             "connection -- that would let one harness act as another's. Got: #{text}"
  end
end
