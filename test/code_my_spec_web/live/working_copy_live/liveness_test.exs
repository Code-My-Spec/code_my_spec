defmodule CodeMySpecWeb.WorkingCopyLive.LivenessTest do
  @moduledoc """
  The page may only repeat what a device said.

  Rule 5 of story 957 — "the page never shows as running something that has
  stopped reporting" — and the sharper form in criterion 2836's own spex: the
  claim about what is running has to come from the harness's claim, not from
  what the server remembers asking for.

  The spex exercises the reap-after-report path, which was always right. This
  covers the case it cannot reach: an agent `start_agent/2` wrote and no device
  ever confirmed. Nothing reports it, so nothing reaps it, and reading `engine`
  without `status` made it claim presence on a channel it had never joined —
  indefinitely, and in the reassuring direction.
  """

  use ExUnit.Case, async: true

  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @now ~U[2026-08-23 12:00:00Z]

  defp agent(status, engine, minutes_ago) do
    %{
      status: status,
      engine: engine,
      updated_at: DateTime.add(@now, -minutes_ago * 60, :second)
    }
  end

  describe "an agent nobody has confirmed" do
    test "does not claim presence on a channel it never joined" do
      summary = Liveness.agent(agent(:starting, :pi, 5), @now)

      refute summary.label =~ "Running",
             "a :starting row is a request, not a report. `start_agent/2` writes it " <>
               "and only `record_reported/2` moves it to :running, so calling it " <>
               "Running is the server reading its own intention back as evidence — " <>
               "and it reads as healthy, which is the direction that costs money."

      refute summary.basis =~ "present",
             "the basis names the signal, and there is no signal here"
    end

    test "says what it is instead of going blank" do
      summary = Liveness.agent(agent(:starting, :pi, 5), @now)

      assert summary.label == "Starting"
      assert summary.since == "5m ago"
    end

    test "does not roll up into a Running copy" do
      summary = Liveness.working_copy([agent(:starting, :pi, 2)], @now)

      refute summary.label =~ "Running",
             "the list summary is what most people read without opening anything, " <>
               "so the same lie at the copy level is the more expensive one"

      assert summary.label == "Starting"
    end

    test "does not mask a lane that really is present beside it" do
      summary =
        Liveness.working_copy([agent(:starting, :pi, 2), agent(:running, :pi, 1)], @now)

      assert summary.label == "Running"
      assert summary.basis == "1 agent present on the harness channel"
    end
  end

  describe "a confirmed agent" do
    test "a running Pi lane is present, on the evidence of the channel" do
      summary = Liveness.agent(agent(:running, :pi, 0), @now)

      assert summary.label == "Running"
      assert summary.basis == "present on the harness channel"
    end

    test "a running Claude Code agent is recency, and says so" do
      summary = Liveness.agent(agent(:running, :claude_code, 12), @now)

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
end
