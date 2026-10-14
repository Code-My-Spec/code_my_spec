defmodule CodeMySpec.Agents.ADeadContinuousAgentIsRestartedTest do
  @moduledoc """
  2999a0cb — an agent whose process died stayed dead, and nothing said so.

  metric_flow's main agent crashed at 22:49:38Z; its row still read
  `:running` until the next report reaped it, and fifteen minutes passed
  before a person noticed.

  Restarting it is its harness's now: the agent's `Engine.Keeper` restarts a
  crashed process with its history and gives up on a crash loop. What reaches
  the server is the cause, as an `agent_died` turn event, written into the
  agent's thread — said to it, not by it. The server restarts nothing on it:
  a second restarter is how one death got restarted twice.
  """
  use CodeMySpecTest.DataCase, async: true

  @moduletag :capture_log

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.RestartRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    CodeMySpecTest.AgentTransportRouter.route(scope, RecordingAgentTransport)
    RecordingAgentTransport.listen(scope)
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

    AgentPresence.present(agent)

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

  test "the death is in its thread, said to it rather than by it", ctx do
    agent = an_agent(ctx.scope, ctx.copy, %{})

    died(ctx.scope, agent)

    assert Enum.any?(thread(ctx.scope, agent), fn {role, text} ->
             role == :operator and text =~ "died at" and text =~ "Protocol.UndefinedError"
           end)
  end

  test "the server restarts nothing on it; its harness does", ctx do
    agent = an_agent(ctx.scope, ctx.copy, %{})

    died(ctx.scope, agent)

    refute_receive {:agent_dispatch, _, _, _}, 300
    assert [] = RestartRepository.unresolved_reasons(Repo.get(Agent, agent.id))
  end
end
