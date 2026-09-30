defmodule CodeMySpec.MainAgent.AnAgentTimingOutIsNotQuietTest do
  @moduledoc """
  eb09b076 — metric_flow's coder lost turn after turn to "claude exec timed out
  after 180000ms", and `check_in` and `list_agent_work` showed it as holding its
  task and recently heard from: a healthy-looking agent that did nothing.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.MainAgent
  alias CodeMySpec.MainAgent.{AgentWork, CheckInReport, Digest, Machinery}
  alias CodeMySpec.McpServers.MainAgent.AgentWorkMapper

  @timeout "claude exec timed out after 180000ms"

  defp entry(overrides) do
    struct!(
      %AgentWork{
        agent_id: Ecto.UUID.generate(),
        role: :coding,
        agent_status: :running,
        working_copy_id: Ecto.UUID.generate(),
        task_name: "bdd_specs_passing",
        task_status: :active,
        machine_tools: ["promote"]
      },
      overrides
    )
  end

  defp timing_out(count), do: entry(turn_timeouts: %{count: count, exec: "claude exec"})

  defp digest(work),
    do: %Digest{questions: [], machinery: %Machinery{tool_fault: :none}, work: work}

  describe "the wording" do
    test "the check-in names the run of timed-out turns on the agent line" do
      report = CheckInReport.render(digest([timing_out(6)]))

      assert report =~ "task: bdd_specs_passing; last 6 turns timed out (claude exec)"
    end

    test "one timed-out turn is said in the singular" do
      assert CheckInReport.render(digest([timing_out(1)])) =~ "last turn timed out (claude exec)"
    end

    test "list_agent_work prints the run, and prints its absence" do
      assert AgentWorkMapper.text([timing_out(6)]) =~
               "recent turns: last 6 turns timed out (claude exec)"

      assert AgentWorkMapper.text([entry([])]) =~ "recent turns: none timed out"
    end

    test "an agent timing out is not quiet" do
      refute Digest.quiet?(digest([timing_out(2)]))
      assert Digest.quiet?(digest([entry([])]))
    end
  end

  describe "read off the transcript" do
    setup do
      scope = full_scope_fixture()

      {:ok, agent} =
        AgentsRepository.create_agent(scope, %{
          provider: "claude-code",
          engine: :alloy,
          role: "coding",
          continuous: true,
          status: :running,
          working_copy: "/tmp/timing-out-#{System.unique_integer([:positive])}",
          working_copy_id: scope.active_working_copy_id
        })

      %{scope: scope, agent: agent}
    end

    defp said(scope, agent, event), do: :ok = Agents.record_turn_event(scope, agent.id, event)

    defp failed(scope, agent, text \\ @timeout),
      do: said(scope, agent, %{"kind" => "turn_failed", "text" => text})

    defp timeouts(scope, agent),
      do: Enum.find(MainAgent.list_agent_work(scope), &(&1.agent_id == agent.id)).turn_timeouts

    test "the latest consecutive timed-out turns are counted", %{scope: scope, agent: agent} do
      failed(scope, agent)
      said(scope, agent, %{"kind" => "message", "text" => "Claiming story 45."})
      for _ <- 1..3, do: failed(scope, agent)

      assert %{count: 3, exec: "claude exec"} = timeouts(scope, agent)
    end

    test "a turn that says anything ends the run", %{scope: scope, agent: agent} do
      for _ <- 1..3, do: failed(scope, agent)
      said(scope, agent, %{"kind" => "message", "text" => "Back to story 45."})

      assert timeouts(scope, agent) == nil
    end

    test "a failure that is not a timeout is not counted", %{scope: scope, agent: agent} do
      failed(scope, agent, "claude exec failed with status 1: boom")

      assert timeouts(scope, agent) == nil
    end
  end
end
