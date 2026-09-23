defmodule CodeMySpec.MainAgent.AnIdleAgentWithWorkIsNotQuietTest do
  @moduledoc """
  `Digest.quiet?/1` decides whether the cadence bothers the main agent, and it
  used to call a stalled fleet quiet.

  `Cadence`'s own docs describe it as "a floor, not a schedule ... the longest
  anything can go unseen", and the design it belongs to is that every wake is
  edge-triggered with the cadence as the safety net under all of them.
  `Work.consider_*` fires on a graph change, a finished task, continuous being
  switched on, a harness joining — nothing polls — so a missed edge is a
  permanent stall. The net could not catch any of it while an agent with nothing
  in hand and a non-empty queue counted as settled.

  Measured 2026-09-23 on Broken Oaths: four distinct missed edges were found and
  fixed individually in one night, and afterwards QA still sat running,
  continuous, zero declines, no turn open, with `get_next_requirement` answering
  "ready — QaStory story 950" and no edge coming.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.MainAgent.{AgentWork, Digest}

  defp entry(overrides) do
    struct!(
      %AgentWork{
        agent_id: Ecto.UUID.generate(),
        role: :qa,
        agent_status: :running,
        working_copy_id: Ecto.UUID.generate(),
        task_status: nil,
        idle?: true,
        turn_started_at: nil,
        tapped_out?: false,
        blocked_reasons: [],
        problems: [],
        machine_tools: ["promote"]
      },
      overrides
    )
  end

  defp digest(work), do: %Digest{questions: [], machinery: nil, work: work}

  test "an agent with no task and a queue that holds work is not quiet" do
    refute Digest.quiet?(digest([entry(idle?: false)])),
           """
           The one state the cadence exists to catch read as settled.

           `idle?` is "no task AND the queue is empty". No task with a queue that
           does hold work means the agent should be working and is not — which is
           exactly what CheckInReport renders as "no task claimed, and the graph
           does hold work for its role", while quiet?/1 suppressed the check-in
           that would have carried it.
           """
  end

  test "an agent with genuinely nothing to do is quiet" do
    assert Digest.quiet?(digest([entry(idle?: true)])),
           "an empty queue is the normal resting state and must not page anybody"
  end

  test "an agent holding a task is quiet whatever its queue says" do
    refute_stalled(entry(task_status: :active, idle?: false))
  end

  test "an agent mid-turn is quiet" do
    refute_stalled(entry(idle?: false, turn_started_at: DateTime.utc_now()))
  end

  # Being left alone is the answer to its own request.
  test "a tapped-out agent is left alone" do
    refute_stalled(entry(idle?: false, tapped_out?: true))
  end

  test "a stopped agent is not stalled — it is stopped" do
    refute_stalled(entry(agent_status: :stopped, idle?: false))
  end

  defp refute_stalled(entry) do
    assert Digest.quiet?(digest([entry]))
  end
end
