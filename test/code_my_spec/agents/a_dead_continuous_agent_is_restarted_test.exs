defmodule CodeMySpec.Agents.ADeadContinuousAgentIsRestartedTest do
  @moduledoc """
  2999a0cb — an agent whose process died stayed dead, and nothing said so.

  metric_flow's main agent crashed at 22:49:38Z; its row still read
  `:running` until the next report reaped it, `list_agent_work` then dropped
  it, and the reaped-agent restart only runs when a harness joins. Fifteen
  minutes passed before a person noticed.

  The harness now reports the death as an `agent_died` turn event. The server
  writes it into the agent's thread, marks the row reaped, and restarts a
  continuous agent through `MainAgent.restart_agent/3` — the path that already
  refuses an agent that is off and stops after three restarts that changed
  nothing.
  """
  use CodeMySpecTest.DataCase, async: false

  @moduletag :capture_log

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Agents.Main.RestartRepository
  alias CodeMySpec.Repo
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp an_agent(scope, copy, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: "coding",
            continuous: true,
            status: :running,
            working_copy: "/tmp/died-#{System.unique_integer([:positive])}",
            working_copy_id: copy.id
          },
          attrs
        )
      )

    agent
  end

  defp died(scope, agent) do
    Agents.record_turn_event(scope, agent.id, %{
      "kind" => "agent_died",
      "text" => "an exception was raised: ** (Protocol.UndefinedError) MCP.Error"
    })
  end

  defp thread(scope, agent) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    conversation |> Conversations.list_messages() |> Enum.map(&{&1.role, text(&1)})
  end

  defp text(message), do: Enum.map_join(message.content, "", &(&1["text"] || ""))

  test "a continuous agent that died is restarted, told why", ctx do
    agent = an_agent(ctx.scope, ctx.copy, %{})
    agent_id = agent.id

    died(ctx.scope, agent)

    assert_receive {:agent_dispatch, ^agent_id, _ref, "Restarted: " <> _}, 5_000
    refute Repo.get(Agent, agent.id).status == :stopped
  end

  test "the death is in its thread, said to it rather than by it", ctx do
    agent = an_agent(ctx.scope, ctx.copy, %{})
    agent_id = agent.id

    died(ctx.scope, agent)
    assert_receive {:agent_dispatch, ^agent_id, _ref, _}, 5_000

    assert Enum.any?(thread(ctx.scope, agent), fn {role, text} ->
             role == :operator and text =~ "died at" and text =~ "Protocol.UndefinedError"
           end)

    # Written as the agent speaking, a death would resolve the restart it caused,
    # and an agent that dies on every turn would be restarted forever.
    assert [_restart] = RestartRepository.unresolved_reasons(Repo.get(Agent, agent.id))
  end

  test "an agent that was not continuous is recorded dead, not restarted", ctx do
    agent = an_agent(ctx.scope, ctx.copy, %{continuous: false})

    died(ctx.scope, agent)

    stopped = Repo.get(Agent, agent.id)
    assert stopped.status == :stopped
    assert stopped.stopped_reason == :reaped
    refute_received {:agent_dispatch, _, _, _}
    assert Enum.any?(thread(ctx.scope, agent), fn {_role, text} -> text =~ "died at" end)
  end
end
