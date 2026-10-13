defmodule CodeMySpec.Agents.Mailbox.SendingNowStopsABusyAgentsTurnTest do
  @moduledoc """
  Sending a waiting message now asks the agent's machine to stop its running
  turn; an idle agent has nothing to stop (story 1051, criterion 2179).

  It used to wait for the turn's next tool boundary, and the server handed it
  over only inside a turn the mailbox had started: a correction to team 2's
  coder waited out sixteen minutes of the work it was correcting (2026-10-13).
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :coding,
        status: :running,
        working_copy: "/tmp/send-now",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)
    %{scope: scope, agent: agent}
  end

  defp mid_turn(%{scope: scope, agent: agent}) do
    :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_started"})
  end

  test "a message sent now to a busy agent stops its turn", ctx do
    mid_turn(ctx)

    {:ok, _, _} =
      Agents.dispatch_message(ctx.scope, ctx.agent.id, "Stop and merge main.", :operator_message,
        send_now: true
      )

    agent_id = ctx.agent.id
    assert_receive {:turn_interrupted, ^agent_id}
  end

  test "a message sent now to an idle agent stops nothing", ctx do
    {:ok, _, _} =
      Agents.dispatch_message(ctx.scope, ctx.agent.id, "Start on 1017.", :operator_message,
        send_now: true
      )

    refute_received {:turn_interrupted, _}
  end
end
