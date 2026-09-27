defmodule CodeMySpec.Agents.ARoleGrantReachesAnExistingAgentTest do
  @moduledoc """
  A grant added to a role reaches agents that already exist.

  Issue `c5df88e7`. The row's `tools` was written at start and `run_script`
  enforced from it, so `install_credo_checks` for coding and
  `read_project_file` for qa sat in `ToolSets` while every running agent was
  refused them until something happened to restart it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.{AgentsRepository, ToolSets}
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  test "a coding agent whose row predates a grant can call it" do
    scope = full_scope_fixture()

    # Coding's current grants minus one: a row written before `list_rules` was
    # added to the role.
    stale = ToolSets.for_role(:coding) -- ["list_rules"]

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/role-grant-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id,
        tools: stale
      })

    assert "list_rules" in Agents.tools_of(scope, agent)

    frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

    {:reply, response, _frame} =
      RunScript.execute(%{script: "return list_rules({})", agent_id: agent.id}, frame)

    answer = response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")

    refute answer =~ "is not a tool a coding agent carries",
           "a grant on the role did not reach an existing agent:\n\n#{answer}"
  end
end
