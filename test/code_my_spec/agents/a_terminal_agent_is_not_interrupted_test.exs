defmodule CodeMySpec.Agents.ATerminalAgentIsNotInterruptedTest do
  @moduledoc """
  Story 1123: a terminal Claude Code session reads a message at its next tool
  call, and nothing can stop its turn. Sending one now says so rather than
  promising an interrupt.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)
    root = "/workspace/terminal-#{System.unique_integer([:positive])}"

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        root: root,
        device: device_fixture(scope)
      )

    {:ok, copy} = CodeMySpec.WorkingCopies.report_root(copy, root)
    scope = %{scope | active_working_copy_id: copy.id}
    {:ok, agent} = Agents.register_terminal(scope, "cc-#{System.unique_integer([:positive])}")
    AgentPresence.present(agent)

    %{scope: scope, agent: agent}
  end

  test "message_agent sent now to a terminal agent says it reads it at its next tool call", %{
    scope: scope,
    agent: agent
  } do
    assert {:ok, said} =
             ToolLibrary.run(
               "message_agent",
               %{"agent_id" => agent.id, "message" => "Stop and rebase.", "send_now" => true},
               %{scope: scope}
             )

    assert said =~ "next tool call"
    assert said =~ "cannot be interrupted"
  end

  test "sent without send_now, nothing is said about interrupting", %{scope: scope, agent: agent} do
    assert {:ok, said} =
             ToolLibrary.run(
               "message_agent",
               %{"agent_id" => agent.id, "message" => "When you're free, rebase."},
               %{scope: scope}
             )

    refute said =~ "cannot be interrupted"
  end
end
