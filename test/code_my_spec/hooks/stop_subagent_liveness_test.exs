defmodule CodeMySpec.Hooks.StopSubagentLivenessTest do
  @moduledoc """
  The stop hook skips validation while a subagent is working. An open task is
  not evidence that one is.

  The exemption keyed on `task.status == :active and agent_id != nil`, and a
  task row outlives the agent that owned it. A subagent that is killed, crashes,
  or is stopped by the operator never completes its task, so the row stays
  `:active` for ever — and the parent session can no longer be blocked by
  anything at all: failing tests, failing spex, a broken build.

  Measured 2026-08-20. Two rows on one session claimed subagents were working:

      ● qa_complete — [active] agent=qa-873b
      ● qa_complete — [active] agent=aqa-727-8475683e9d966b73

  Both belonged to QA subagents the operator had stopped hours earlier. At the
  same moment `list_session_subagents`, which filters registrations by
  `subagent_ttl_minutes`, answered "No registered sub-agents on this session".
  The registrations were right; the task rows were tombstones. That session
  spent hours exempt from a failing spex suite that was actively stopping a
  different agent on the same project — and reported itself as simply not having
  been blocked.

  So the question is asked of the thing that expires. These pin the rule against
  the ledger of live agent ids rather than against the task list alone.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.Task

  defp session(tasks), do: %Session{tasks: tasks}

  defp task(attrs), do: struct(Task, Map.merge(%{status: :active, agent_id: nil}, attrs))

  describe "subagent_task_live?/2" do
    test "a task whose owner is still registered exempts the parent" do
      s = session([task(%{agent_id: "qa-873b"})])

      assert Stop.subagent_task_live?(s, MapSet.new(["qa-873b"])),
             "this is what the exemption is for — a subagent mid-flight should not " <>
               "have the parent's stop hook hammering it"
    end

    # The regression. Before this, the task row alone was the whole test.
    test "a task whose owner is gone does not" do
      s = session([task(%{agent_id: "qa-873b"})])

      refute Stop.subagent_task_live?(s, MapSet.new([])),
             "the subagent was stopped and never completed its task, so the row " <>
               "outlived it. Treating that as work in flight leaves the parent " <>
               "unblockable for the rest of the session, silently."
    end

    test "one live owner among several dead ones is enough" do
      s =
        session([
          task(%{agent_id: "stopped-1"}),
          task(%{agent_id: "stopped-2"}),
          task(%{agent_id: "still-working"})
        ])

      assert Stop.subagent_task_live?(s, MapSet.new(["still-working"]))
    end

    # An unassigned task is the main agent's own work — `start_task` without an
    # `agent_id` — and was never meant to exempt anything. Pinned because the
    # first diagnosis of the incident above blamed exactly this and was wrong.
    test "an unassigned active task never exempts, live ids or not" do
      s = session([task(%{agent_id: nil})])

      refute Stop.subagent_task_live?(s, MapSet.new(["anything"]))
      refute Stop.subagent_task_live?(s, MapSet.new([]))
    end

    test "a completed task does not exempt even while its agent is live" do
      s = session([task(%{status: :completed, agent_id: "qa-873b"})])

      refute Stop.subagent_task_live?(s, MapSet.new(["qa-873b"]))
    end

    test "no tasks at all is not an exemption" do
      refute Stop.subagent_task_live?(session([]), MapSet.new(["qa-873b"]))
      refute Stop.subagent_task_live?(session(nil), MapSet.new(["qa-873b"]))
    end
  end
end
