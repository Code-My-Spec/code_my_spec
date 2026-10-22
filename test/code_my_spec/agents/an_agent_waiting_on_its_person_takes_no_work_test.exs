defmodule CodeMySpec.Agents.AnAgentWaitingOnItsPersonTakesNoWorkTest do
  @moduledoc """
  A terminal session waiting on its person (a permission prompt) is shown so,
  and is offered no work it cannot take. Issue 3e1b3ac8, story 1127.

  Claude Code's own agent list says only busy or idle; the Notification hook is
  what tells the harness the session is waiting.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.TerminalAgentFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work

  setup do
    scope = full_scope_fixture()
    agent = terminal_agent_fixture(scope, %{role: :coding, continuous: true})
    CodeMySpecTest.AgentPresence.present(agent)
    %{scope: scope, agent: agent}
  end

  defp reload(scope, agent) do
    {:ok, agent} = AgentsRepository.fetch_agent(scope, agent.id)
    agent
  end

  test "a waiting report marks the agent, and a turn starting clears it", %{
    scope: scope,
    agent: agent
  } do
    :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "waiting"})
    assert %DateTime{} = reload(scope, agent).waiting_since

    :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "turn_started"})
    assert is_nil(reload(scope, agent).waiting_since)
  end

  test "a tool call the session starts or ends is the tool it is running", %{
    scope: scope,
    agent: agent
  } do
    :ok =
      Agents.record_turn_event(scope, agent.id, %{
        "kind" => "tool_activity",
        "tool" => %{"name" => "Bash", "input" => %{"command" => "mix test"}}
      })

    assert %{current_tool: "Bash", turn_tool_count: 1} = reload(scope, agent)

    :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "tool_activity", "tool" => nil})
    assert is_nil(reload(scope, agent).current_tool)
  end

  test "work is not offered to an agent waiting on its person", %{scope: scope, agent: agent} do
    assert Work.admission(scope, reload(scope, agent), :work_offer) == :ok

    :ok = Agents.record_turn_event(scope, agent.id, %{"kind" => "waiting"})

    assert {:hold, _} = Work.admission(scope, reload(scope, agent), :work_offer)
  end
end
