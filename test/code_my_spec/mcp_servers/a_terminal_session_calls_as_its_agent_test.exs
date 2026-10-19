defmodule CodeMySpec.McpServers.ATerminalSessionCallsAsItsAgentTest do
  @moduledoc """
  Story 1122: a terminal Claude Code session's tool calls carry its session id
  (the PreToolUse hook injects it), and that names its agent as the caller —
  so a task it starts is its agent's, and a role-bound requirement (QA's
  `qa_complete`) is offered to it. Found live, 2026-10-18: a terminal QA agent's
  `start_task` was owned by its plain session, which holds no role.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.LibraryTools

  setup do
    scope = full_scope_fixture()
    root = "/workspace/caller-#{System.unique_integer([:positive])}"

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        root: root,
        device: device_fixture(scope)
      )

    {:ok, copy} = CodeMySpec.WorkingCopies.report_root(copy, root)
    %{scope: %{scope | active_working_copy_id: copy.id}}
  end

  test "a call carrying a terminal session's id is its agent's", %{scope: scope} do
    session = "cc-#{System.unique_integer([:positive])}"
    {:ok, agent} = Agents.register_terminal(scope, session)

    context = LibraryTools.context(scope, %{session_id: session}, %Frame{assigns: %{}})

    assert context.agent_id == agent.id
    assert context.session_id == session
  end

  test "an agent named on the connection still wins", %{scope: scope} do
    session = "cc-#{System.unique_integer([:positive])}"
    {:ok, _terminal} = Agents.register_terminal(scope, session)
    ours = Ecto.UUID.generate()

    context =
      LibraryTools.context(scope, %{session_id: session}, %Frame{assigns: %{agent_id: ours}})

    assert context.agent_id == ours
  end

  test "a session that is no terminal agent calls as itself", %{scope: scope} do
    context = LibraryTools.context(scope, %{session_id: "cc-unknown"}, %Frame{assigns: %{}})

    refute Map.has_key?(context, :agent_id)
  end
end
