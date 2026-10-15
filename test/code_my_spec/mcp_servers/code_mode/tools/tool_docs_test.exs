defmodule CodeMySpec.McpServers.CodeMode.Tools.ToolDocsTest do
  @moduledoc """
  An agent we run carries the same direct tools regardless of role
  (`ToolIndex.carried/1`) -- role only scopes `run_script` (`ToolSets.for_role`).
  `tool_docs`'s direct-carrying check tested direct tool names against that
  scriptable grant list instead, so a role-restricted agent was told it did
  not carry tools it actually had, such as `get_next_requirement`. Issue
  `73a1ca46`.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs

  defp text(response) do
    response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")
  end

  defp coding_agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :coding,
        working_copy: scope.cwd || "/workspace/main",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  describe "a direct-only tool, for an agent we run" do
    test "is carried, even though it is absent from the role's scriptable grants" do
      scope = full_scope_fixture()
      agent = coding_agent(scope)
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert {:reply, response, ^frame} =
               ToolDocs.execute(%{name: "get_next_requirement"}, frame)

      body = text(response)

      assert body =~ "You carry it directly"
      refute body =~ "You do not carry it"
    end

    test "a tool the engine itself does not carry is still correctly refused" do
      scope = full_scope_fixture()
      agent = coding_agent(scope)
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert {:reply, response, ^frame} = ToolDocs.execute(%{name: "health"}, frame)

      body = text(response)

      assert body =~ "You do not carry it"
      refute body =~ "this role is given"
    end
  end
end
