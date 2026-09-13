defmodule CodeMySpec.MainAgent.ARestartThatChangedNothingTest do
  @moduledoc """
  An agent that does not recover, which is the state black-box QA could never
  produce.

  Issue `4b248103`. A restart resolves itself the moment the agent speaks, and a
  healthy agent starts streaming within seconds of the restart's own injected
  message — so on a live machine every restart is resolved before a second one
  can be attempted, and the three-strike refusal never accumulates. QA fired
  four back-to-back restarts for one reason and all four were accepted, which is
  correct behaviour and indistinguishable from the guard not existing.

  The fault makes the agent count as never having spoken, keyed on its own id.
  `nil` rather than a fabricated old timestamp, because "never spoken" is a
  state this module already has clauses for — so what the fault produces is a
  real shape rather than a plausible-looking one.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Conversations
  alias CodeMySpec.Faults
  alias CodeMySpec.MainAgent.RestartRepository

  setup do
    scope = full_scope_fixture()

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: "/tmp/silent-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    on_exit(fn -> Faults.clear(agent.id, :agent_stays_silent) end)

    %{scope: scope, agent: agent, conversation: conversation}
  end

  defp restarted(agent, reason) do
    {:ok, _} = RestartRepository.record(agent, reason)
    :ok
  end

  defp spoke(conversation) do
    {:ok, _} = Conversations.add_message(conversation, :assistant, "on it")
    :ok
  end

  describe "an agent that answers" do
    test "resolves the restarts that woke it", %{agent: agent, conversation: conversation} do
      :ok = restarted(agent, "you have gone quiet")
      :ok = spoke(conversation)

      assert RestartRepository.unresolved(agent, "you have gone quiet") == [],
             "the premise failed: a speaking agent still reads as unrecovered"
    end
  end

  describe "an agent that does not" do
    test "accumulates them, which is what the guard counts", %{
      agent: agent,
      conversation: conversation
    } do
      :ok = Faults.inject(agent.id, :agent_stays_silent)

      :ok = restarted(agent, "you have gone quiet")
      :ok = spoke(conversation)
      :ok = restarted(agent, "you have gone quiet")
      :ok = spoke(conversation)

      assert length(RestartRepository.unresolved(agent, "you have gone quiet")) == 2, """
      The agent spoke and the restarts resolved anyway, so the state every
      "a restart changed nothing" criterion is about is still unreachable — the
      system settles it faster than anything can observe it (4b248103).
      """
    end

    test "and reaches that agent only", %{scope: scope, agent: agent} do
      {:ok, neighbour} =
        AgentsRepository.create_agent(scope, %{
          provider: "anthropic",
          engine: :alloy,
          role: "coding",
          working_copy: "/tmp/speaking-#{System.unique_integer([:positive])}",
          working_copy_id: scope.active_working_copy_id
        })

      {:ok, their_conversation} =
        Conversations.find_or_create_agent_conversation(
          scope.active_account_id,
          scope.active_project_id,
          neighbour.id
        )

      :ok = Faults.inject(agent.id, :agent_stays_silent)

      :ok = restarted(neighbour, "you have gone quiet")
      :ok = spoke(their_conversation)

      assert RestartRepository.unresolved(neighbour, "you have gone quiet") == [], """
      Silencing one agent silenced another. A fault that reaches the fleet is
      the node-global switch this whole seam exists to replace (0fb7bf03).
      """
    end
  end
end
