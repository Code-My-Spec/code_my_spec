defmodule CodeMySpec.Agents.Main.AnAgentOutOfTheLoopIsNotReportedStalledTest do
  @moduledoc """
  An agent with continuous off is reported as out of the loop, not STALLED.

  723b929d. metric_flow's main agent `a89e670d` was never woken when deploy
  became actionable after QA passed story 48. The graph change did fire the
  project-wide wake; `Work.runnable_state?/1` skipped main because its
  `continuous` was false, as it had been since it was created. `list_agent_work`
  called that "STALLED … no turn open to claim it", which sent the diagnosis
  after a missed edge that was not missing.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Main.AgentWork

  defp unclaimed(continuous?) do
    AgentWork
    |> struct(agent_status: :running, role: :main, continuous?: continuous?)
    |> AgentWork.unclaimed_work()
  end

  test "an agent out of the loop is named as such" do
    line = unclaimed(false)

    refute line =~ "STALLED",
           "an agent graph wakes never admit was reported as a stall: #{line}"

    assert line =~ "continuous off"
  end

  test "a continuous agent with no turn and work waiting is still STALLED" do
    assert unclaimed(true) =~ "STALLED"
  end
end
