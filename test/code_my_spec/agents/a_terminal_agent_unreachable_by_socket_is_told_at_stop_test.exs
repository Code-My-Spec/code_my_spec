defmodule CodeMySpec.Agents.ATerminalAgentUnreachableBySocketIsToldAtStopTest do
  @moduledoc """
  Story 1123: a terminal session that cannot take socket messages — its
  Claude Code is too old, or it holds or refuses them — is told why when it
  starts, and is handed what was waiting when it stops.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Hooks.SessionStart
  alias CodeMySpec.Hooks.Stop
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
    assert context =~ "handed to you when you stop"
  end

  test "a session reached by socket hears nothing about stopping", %{scope: scope} do
    assert {200, body} =
             SessionStart.handle(scope, %{
               "session_id" => session_id(),
               "messaging" => %{"delivery" => "socket"}
             })

    refute body.hookSpecificOutput.additionalContext =~ "when you stop"
  end

  test "what waited for an agent nothing reaches is handed over once, at its stop", %{
    scope: scope
  } do
    session = session_id()
    {:ok, agent} = Agents.register_terminal(scope, session)

    {:ok, _, _} =
      Agents.dispatch_message(
        scope,
        agent.id,
        "Rebase on main before you go on.",
        :operator_message
      )

    assert %{"decision" => "block", "reason" => reason} =
             Stop.decide(scope, %{"session_id" => session})

    assert reason =~ "Rebase on main before you go on."

    refute match?(
             %{"reason" => "Messages for you" <> _},
             Stop.decide(scope, %{"session_id" => session})
           )
  end
end
