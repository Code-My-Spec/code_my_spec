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

  # 50ddc827: `list_session_subagents` sits in every role's scriptable
  # catalog (`Layer.catalog/1` is unfiltered), so reading its schema here
  # looked like permission to call it -- the refusal only arrived later, at
  # `run_script`'s own gate (`ToolSets.for_role/1`), which coding never
  # carries this tool in.
  describe "a scriptable tool outside the caller's role grant" do
    test "is still fully documented, but marked not available to this role" do
      scope = full_scope_fixture()
      agent = coding_agent(scope)
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert {:reply, response, ^frame} =
               ToolDocs.execute(%{name: "list_session_subagents"}, frame)

      body = text(response)

      assert body =~ "session_id", "the real schema must still be printed"
      assert body =~ "Not available to your role"
    end

    # 10586b7f: a second, distinct tool (`list_agents`, main-only per
    # RoleProfile -- staffing is main's) showed the identical gap after
    # 50ddc827's fix landed for `list_session_subagents` alone: tool_docs is
    # not restricted to naming one tool; the grant check has to run for
    # whichever tool is asked about, not just the one the first report named.
    test "a second main-only tool is also marked unavailable to coding" do
      scope = full_scope_fixture()
      agent = coding_agent(scope)
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert {:reply, response, ^frame} = ToolDocs.execute(%{name: "list_agents"}, frame)

      body = text(response)

      assert body =~ "working copy", "the real schema must still be printed"
      assert body =~ "Not available to your role"
    end

    test "carries no such note for a role the grant does not restrict" do
      scope = full_scope_fixture()
      agent = AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "anthropic",
        role: :main,
        working_copy: scope.cwd || "/workspace/main",
        working_copy_id: scope.active_working_copy_id
      })
      {:ok, agent} = agent
      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert {:reply, response, ^frame} =
               ToolDocs.execute(%{name: "list_session_subagents"}, frame)

      refute text(response) =~ "Not available to your role"
    end

    test "carries no such note for a role the grant does include it in" do
      scope = full_scope_fixture()

      {:ok, agent} =
        AgentsRepository.create_agent(scope, %{
          engine: :alloy,
          provider: "anthropic",
          role: :qa,
          working_copy: scope.cwd || "/workspace/main",
          working_copy_id: scope.active_working_copy_id
        })

      frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

      assert {:reply, response, ^frame} =
               ToolDocs.execute(%{name: "list_session_subagents"}, frame)

      refute text(response) =~ "Not available to your role"
    end
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
