defmodule CodeMySpec.Problems.StaleOnArrivalTest do
  @moduledoc """
  A run slower than the edit cadence is stale the instant it finishes, and
  saying "stale, last ran 0s ago" sends the reader to wait for a rerun that
  lands in the same state.

  A run is fingerprinted when it is enqueued and judged against the tree when
  it is read. Measured on this harness: compiler 9s, credo 10s, exunit 2m20s,
  spex 2m35s. An agent editing every couple of minutes — the normal working
  rhythm — keeps exunit and spex permanently stale without doing anything
  unusual, and the observed shape was a staleness that climbed and never
  resolved: 33s, 2m, 5m, 7m, 7m across consecutive stops, with runs completing
  throughout.

  The age alone cannot express this. "Stale, last ran 2m ago" is mid-cycle
  advice when the run takes 10s and a description of a structural condition
  when it takes 2m20s, and the two need opposite responses. So the duration
  travels with the age, and where the edit landed inside the run's own window
  the message says so and stops advising a wait.

  This does not change what blocks — the findings are real results from a real
  run, one edit behind — only what the reader is told to do about them.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.ProblemRenderer

  defp problem(source) do
    %CodeMySpec.Problems.Problem{
      source: source,
      severity: :error,
      file_path: "lib/a.ex",
      line: 1,
      message: "something",
      category: "x"
    }
  end

  defp render(source, seconds_ago, opts) do
    ProblemRenderer.render_stop_response(
      [problem(source)],
      [],
      [
        stale_sources: [source],
        last_ran: %{source => DateTime.add(DateTime.utc_now(), -seconds_ago, :second)}
      ] ++ opts
    )
  end

  describe "an edit that landed while the run was in flight" do
    test "the marker says how long the run takes, not just how old it is" do
      out = render("exunit", 0, run_duration: %{"exunit" => 140})

      refute out =~ "last ran 0s ago:",
             ~s(a run that finished this second is not "stale" in any sense the ) <>
               "reader can act on, and saying so is what sent five consecutive " <>
               "stops to wait for a rerun"

      assert out =~ "2m20s", "the run's own duration is what makes the age legible"
    end

    test "it does not give the ordinary wait advice" do
      out = render("exunit", 8, run_duration: %{"exunit" => 140})

      refute out =~ "Stopping again enqueues one",
             "the ordinary reading — stop, a rerun replaces this — is what loops " <>
               "here, because the next edit overtakes the rerun as it overtook this"

      assert out =~ "will finish stale as well"
    end

    test "it names stopping as what starts a sweep, not a passive wait" do
      # "Pause edits until a sweep completes" was the first wording, and with no
      # rerun in flight it describes a wait for something nothing will start —
      # a stop is what enqueues one. An agent following it edits nothing and
      # waits forever, which is the loop this exists to break wearing new words.
      out = render("exunit", 8, run_duration: %{"exunit" => 140}, in_flight: [])

      assert out =~ "Stopping again enqueues a sweep"

      assert out =~ "without editing",
             "the instruction that makes the next run land current is to stop " <>
               "*and not edit during it*; a stop alone repeats this state"
    end

    test "with a rerun already in flight it says so and gives the same instruction" do
      out = render("exunit", 8, run_duration: %{"exunit" => 140}, in_flight: ["exunit"])

      assert out =~ "in flight",
             "a sweep already running is the one fact that changes what waiting costs"

      assert out =~ "without editing"

      refute out =~ "Stopping again enqueues a sweep",
             "one is already running; enqueueing is not the instruction"
    end

    test "it is not reported as an analyzer failure" do
      out = render("exunit", 8, run_duration: %{"exunit" => 140})

      refute out =~ "treat the analyzer as failing",
             "the analyzer worked — it answered about the tree it was given"
    end

    test "the findings still block" do
      out = render("exunit", 8, run_duration: %{"exunit" => 140})

      assert out =~ "Fix these problems before stopping",
             "one edit behind is not the same as wrong; nothing here opens an escape"
    end
  end

  describe "an edit that predates the run" do
    test "a fast source stale for minutes keeps the wait advice" do
      out = render("credo", 120, run_duration: %{"credo" => 10})

      assert out =~ "last ran 2m ago"
      assert out =~ "persist across several stops"
      refute out =~ "will finish stale as well"
    end

    test "a slow source stale for far longer than it takes still escalates" do
      out = render("exunit", 1_860, run_duration: %{"exunit" => 140})

      assert out =~ "treat the analyzer as failing",
             "31 minutes with no rerun is a wedged analyzer whatever the duration"
    end
  end

  describe "without a duration" do
    test "the message is exactly what it was before" do
      out = render("credo", 120, [])

      assert out =~ "last ran 2m ago"
      assert out =~ "persist across several stops"
      refute out =~ "will finish stale as well"
    end
  end
end
