defmodule CodeMySpecWeb.WorkingCopyLive.LivenessTest do
  @moduledoc """
  The page may only repeat what a device said.

  Rule 5 of story 957 — "the page never shows as running something that has
  stopped reporting" — and the sharper form in criterion 2836's own spex: the
  claim about what is running has to come from the harness's claim, not from
  what the server remembers asking for.

  The claim is presence (`Agents.Presence`), carried on each agent as its
  `lifecycle`. An agent on duty and not present — asked for, being restored,
  awaiting a restart — must not claim to be running.
  """

  use ExUnit.Case, async: true

  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @now ~U[2026-08-23 12:00:00Z]

  defp agent(lifecycle, engine, minutes_ago) do
    at = DateTime.add(@now, -minutes_ago * 60, :second)

    %{
      lifecycle: lifecycle,
      engine: engine,
      updated_at: at,
      off_at: stamped(lifecycle, :off, at),
      retired_at: stamped(lifecycle, :retired, at)
    }
  end

  defp stamped(lifecycle, lifecycle, at), do: at
  defp stamped(_lifecycle, _stamp, _at), do: nil

  describe "an agent on duty and not present" do
    test "does not claim to be running" do
      summary = Liveness.agent(agent(:starting, :alloy, 5), @now)

      refute summary.label =~ "Running",
             "an agent asked for is a request, not a report. Calling it Running is " <>
               "the server reading its own intention back as evidence — and it reads " <>
               "as healthy, which is the direction that costs money."

      refute summary.basis =~ "alive",
             "the basis names the signal, and there is no signal here"
    end

    test "says what it is instead of going blank" do
      summary = Liveness.agent(agent(:starting, :alloy, 5), @now)

      assert summary.label == "Starting"
      assert summary.since == "5m ago"
    end

    test "does not roll up into a Running copy" do
      summary = Liveness.working_copy([agent(:starting, :alloy, 2)], @now)

      refute summary.label =~ "Running",
             "the list summary is what most people read without opening anything, " <>
               "so the same lie at the copy level is the more expensive one"

      assert summary.label == "Starting"
    end

    test "does not mask an agent that really is present beside it" do
      summary =
        Liveness.working_copy([agent(:starting, :alloy, 2), agent(:running, :alloy, 1)], @now)

      assert summary.label == "Running"
      assert summary.basis == "1 agent alive on the harness"
    end
  end

  describe "a present agent" do
    test "is running, as a fact about now rather than evidence with an age" do
      summary = Liveness.agent(agent(:running, :alloy, 0), @now)

      assert summary.label == "Running"
      assert summary.basis == "its process is alive on the harness"
      assert summary.since == nil
    end

    test "a Claude Code agent is recency, and says so" do
      summary = Liveness.agent(agent(:starting, :claude_code, 12), @now)

      assert summary.label == "Last heard from"
      assert summary.since == "12m ago"

      assert summary.basis =~ "recency, not presence",
             "hooks give a timestamp, not a heartbeat. An agent that died ten " <>
               "minutes ago and one mid-thought produce the same one."
    end
  end

  describe "a copy with nothing on it" do
    test "is idle, and says which question was asked" do
      summary = Liveness.working_copy([], @now)

      assert summary.label == "Idle"

      assert summary.basis =~ "no agent reported",
             "'nothing is running here' and 'we did not look' are different " <>
               "claims and the basis is what separates them"
    end
  end

  # John, after clicking the new stop button on his own conversation: "it
  # completely killed the agent. Like it left the list." `list_for_team_status/1`
  # hands this function an agent that was turned off, and reading `engine` alone
  # claimed it present for a process that had just been asked to end.
  describe "an agent turned off" do
    test "does not claim to be running" do
      summary = Liveness.agent(agent(:off, :alloy, 1), @now)

      refute summary.label =~ "Running",
             "asked to stop is not the same claim as alive on the harness"

      assert summary.label == "Off"
      assert summary.since == "1m ago"
    end

    test "does not roll up into a Running copy" do
      summary = Liveness.working_copy([agent(:off, :alloy, 3)], @now)

      assert summary.label == "Stopped"
    end

    # Distinct from "Idle" — that is no agent ever having reported here;
    # this is a slot whose one agent is not running.
    test "reads differently from a copy with nothing on it" do
      idle = Liveness.working_copy([], @now)
      stopped = Liveness.working_copy([agent(:off, :alloy, 3)], @now)

      refute idle.label == stopped.label
    end

    test "does not mask an agent that really is present beside it" do
      summary =
        Liveness.working_copy([agent(:off, :alloy, 10), agent(:running, :alloy, 0)], @now)

      assert summary.label == "Running"
    end
  end

  # Not "Starting": nothing is going to start it (Harness, 2026-10-05).
  describe "an agent its harness gave up on" do
    defp gave_up(minutes_ago) do
      at = DateTime.add(@now, -minutes_ago * 60, :second)

      %{
        agent(:gave_up, :alloy, minutes_ago)
        | updated_at: at
      }
      |> Map.put(:gave_up, %{reason: ":boom", at: at})
    end

    test "says so, with why and since when" do
      summary = Liveness.agent(gave_up(4), @now)

      assert summary.label == "Gave up — needs main"
      assert summary.basis =~ ":boom"
      assert summary.since == "4m ago"
    end

    test "is what the copy reads as when nothing is running on it" do
      summary = Liveness.working_copy([gave_up(4), agent(:starting, :alloy, 1)], @now)

      assert summary.label == "Gave up — needs main"
    end

    test "does not mask an agent that really is running beside it" do
      summary = Liveness.working_copy([gave_up(4), agent(:running, :alloy, 0)], @now)

      assert summary.label == "Running"
    end
  end

  # Story 1124: a terminal session reads by presence, like an agent we run.
  describe "a terminal agent" do
    defp terminal(lifecycle, minutes_ago),
      do: Map.put(agent(lifecycle, :claude_code, minutes_ago), :engine_session_id, "cc-1")

    test "is running while its session is live" do
      summary = Liveness.agent(terminal(:running, 0), @now)

      assert summary.label == "Running"
      assert summary.since == nil
    end

    test "is away, not stalled or starting, when its session has ended" do
      summary = Liveness.agent(terminal(:starting, 30), @now)

      assert summary.label == "Away"
      assert summary.since == "30m ago"
    end

    test "counts as present on its copy while live, and as stopped when away" do
      assert Liveness.working_copy([terminal(:running, 0)], @now).label == "Running"
      assert Liveness.working_copy([terminal(:starting, 5)], @now).label == "Stopped"
    end
  end
end
