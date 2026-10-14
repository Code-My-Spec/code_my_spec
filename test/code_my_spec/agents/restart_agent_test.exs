defmodule CodeMySpec.Agents.RestartAgentTest do
  @moduledoc """
  Restarting an agent whose process a shared harness restart (or a crash)
  took out from under it — same id, same conversation, a fresh process.

  John: "we're persisting the state of a process — just display the state
  of the process, and when you click play it should start the process
  again." `status: :running` on a row nothing is actually holding is what
  this exists to correct: `working_copy_connected?/1` reads the live
  channel registry instead of trusting the column, and `restart_agent/2`
  is what `set_agent_continuous/3` reaches for once it finds nothing there.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Conversations
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

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: false,
        status: :running,
        working_copy: "/tmp/restart-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    {:ok, _} =
      Conversations.add_agent_message(conversation, agent.id, "assistant", "earlier turn")

    %{scope: scope, agent: agent, conversation: conversation}
  end

  describe "working_copy_connected?/1" do
    test "false when nothing is registered for the working copy", %{agent: agent} do
      refute Agents.working_copy_connected?(agent)
    end

    test "true once a channel join registers the copy", %{agent: agent} do
      :ok = HarnessRegistry.register_executor(agent.working_copy_id)

      assert Agents.working_copy_connected?(agent)
    end
  end

  # The half `working_copy_connected?/1` cannot answer.
  #
  # It asks whether the *harness* is connected, which is a different question
  # from whether *this agent's process* is alive, and the two come apart in the
  # ordinary case: an agent deliberately stopped on a machine whose harness is
  # perfectly healthy. That took the wake branch, dispatched to a process that
  # no longer existed, and reported success — so the play button did nothing and
  # the only control that clears `:stopped` could never reach `restart_agent/2`.
  describe "set_agent_continuous/3 on a stopped agent" do
    setup %{scope: scope, agent: agent} do
      # Registered, so the copy reads as connected — this is the case the old
      # check got wrong, not a disconnected machine.
      :ok = HarnessRegistry.register_executor(agent.working_copy_id)
      {:ok, stopped} = AgentsRepository.update_agent(scope, agent, %{status: :stopped})
      :ok = AgentPresence.absent(agent)
      %{agent: stopped}
    end

    test "enables intent without restarting a stopped agent", %{scope: scope, agent: agent} do
      assert Agents.working_copy_connected?(agent),
             "the premise failed: this test is about a stopped agent on a *connected* " <>
               "copy, which is the combination the old check read as alive"

      assert {:ok, updated, :enabled_without_work} =
               Agents.set_agent_continuous(scope, agent.id, true)

      assert updated.id == agent.id
      assert updated.continuous
      assert updated.status == :stopped
      refute_receive {:work_turn_requested, _, _, _}
      refute_receive {:agent_dispatch, _, _, _}
    end

    test "a failed agent also retains its lifecycle state", %{scope: scope, agent: agent} do
      {:ok, failed} = AgentsRepository.update_agent(scope, agent, %{status: :failed})

      assert {:ok, updated, :enabled_without_work} =
               Agents.set_agent_continuous(scope, failed.id, true)

      assert updated.status == :failed
      assert updated.continuous
      refute_receive {:work_turn_requested, _, _, _}
    end
  end

  describe "restart_agent/2" do
    test "keeps the same id", %{scope: scope, agent: agent} do
      {:ok, restarted} = Agents.restart_agent(scope, agent.id)

      assert restarted.id == agent.id
    end

    test "reuses the existing conversation rather than creating a new one", %{
      scope: scope,
      agent: agent,
      conversation: conversation
    } do
      {:ok, _restarted} = Agents.restart_agent(scope, agent.id)

      {:ok, still_the_same} =
        Conversations.find_or_create_agent_conversation(
          scope.active_account_id,
          scope.active_project_id,
          agent.id
        )

      assert still_the_same.id == conversation.id

      texts =
        conversation
        |> Conversations.list_messages()
        |> Enum.flat_map(fn m -> Enum.map(m.content || [], &Map.get(&1, "text", "")) end)

      assert Enum.any?(texts, &(&1 =~ "earlier turn")),
             "a restart that lost the prior transcript is the one outcome this exists to avoid"
    end

    test "asks the machine to run it and records the report", %{scope: scope, agent: agent} do
      {:ok, restarted} = Agents.restart_agent(scope, agent.id)

      assert restarted.status == :running,
             "the machine confirmed the id — record_started/3's whole report"
    end
  end
end
