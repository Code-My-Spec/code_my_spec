defmodule CodeMySpec.Agents.ATerminalAgentUnreachableBySocketIsToldAtStopTest do
  @moduledoc """
  Story 1123: a terminal session that cannot take socket messages — its
  Claude Code is too old, or it holds or refuses them — is told why when it
  starts. Direct messages fail rather than silently falling back to Stop.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Hooks.SessionStart
  alias CodeMySpec.Hooks.Stop
  alias CodeMySpecTest.RecordingAgentTransport
  alias CodeMySpecTest.AgentPresence

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
    %{scope: %{scope | active_working_copy_id: copy.id}}
  end

  defp session_id, do: "cc-#{System.unique_integer([:positive])}"

  test "a session its harness cannot reach by socket is told why at start", %{scope: scope} do
    why = "this Claude Code exposes no messaging socket (it needs v2.1.224 or later)"

    assert {200, body} =
             SessionStart.handle(scope, %{
               "session_id" => session_id(),
               "messaging" => %{"delivery" => "stop_hook", "why" => why}
             })

    context = body.hookSpecificOutput.additionalContext
    assert context =~ why
    assert context =~ "Direct messages require native session messaging"
  end

  test "a session reached by socket hears nothing about stopping", %{scope: scope} do
    assert {200, body} =
             SessionStart.handle(scope, %{
               "session_id" => session_id(),
               "messaging" => %{"delivery" => "socket"}
             })

    refute body.hookSpecificOutput.additionalContext =~ "when you stop"
  end

  test "an unreachable terminal refuses direct delivery without saving a Stop-hook message", %{
    scope: scope
  } do
    session = session_id()
    {:ok, agent} = Agents.register_terminal(scope, session)

    assert {:error, why} =
             Agents.dispatch_message(
               scope,
               agent.id,
               "Rebase on main before you go on.",
               :operator_message
             )

    assert why =~ "Claude's messaging API is unavailable"
    assert Agents.take_held_for_stop(scope, session) == []

    refute inspect(Stop.decide(scope, %{"session_id" => session})) =~
             "Rebase on main before you go on."
  end

  test "a lost native connection does not move an admitted direct message into Stop", %{
    scope: scope
  } do
    session = session_id()
    {:ok, agent} = Agents.register_terminal(scope, session)
    AgentPresence.present(agent)

    assert {:ok, :queued, _} =
             Agents.dispatch_message(scope, agent.id, "Native delivery only.", :operator_message)

    assert_receive {:agent_dispatch, _, _, "Native delivery only."}
    AgentPresence.absent(agent)
    assert Agents.take_held_for_stop(scope, session) == []
  end

  test "an unavailable Codex queue refuses direct messages", %{scope: scope} do
    {:ok, agent} = Agents.register_terminal(scope, session_id(), :main, :codex)

    assert {:error, why} =
             Agents.dispatch_message(scope, agent.id, "Native delivery only.", :operator_message)

    assert why =~ "codex queue is unavailable"
  end
end
