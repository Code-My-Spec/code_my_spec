defmodule CodeMySpec.Agents.ATerminalCanChangeRolesAgainTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  for engine <- [:claude_code, :codex] do
    test "#{engine} can change from coding to product through the scoped tool" do
      scope = full_scope_fixture()

      {:ok, agent} =
        AgentsRepository.create_agent(scope, %{
          provider: "anthropic",
          engine: unquote(engine),
          role: :coding,
          working_copy: "/tmp/terminal-role",
          working_copy_id: scope.active_working_copy_id
        })

      assert "set_my_role" in Agents.tools_of(scope, agent)
      refute "create_story" in Agents.tools_of(scope, agent)
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      {:reply, response, _} =
        RunScript.execute(
          %{
            script: "return set_my_role({role = \"product\"})",
            agent_id: agent.id
          },
          frame
        )

      answer =
        response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")

      assert answer =~ "product agent"
      {:ok, updated} = Agents.fetch_agent(scope, agent.id)
      assert updated.role == :product
      assert updated.engine == unquote(engine)
      assert updated.working_copy_id == agent.working_copy_id
      assert "create_story" in Agents.tools_of(scope, updated)
      assert "set_my_role" in Agents.tools_of(scope, updated)
    end
  end

  test "in-app coding agents keep their assigned seat" do
    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :coding,
        working_copy: "/tmp/in-app-role",
        working_copy_id: scope.active_working_copy_id
      })

    refute "set_my_role" in Agents.tools_of(scope, agent)
    assert {:error, :not_a_terminal_agent} = Agents.set_terminal_role(scope, agent, :product)
  end
end
