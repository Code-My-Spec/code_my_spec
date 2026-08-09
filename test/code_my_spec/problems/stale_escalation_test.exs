defmodule CodeMySpec.Problems.StaleEscalationTest do
  @moduledoc """
  What a stale source's footer claims.

  Two different facts had been collapsed into one sentence. `last_ran` is the
  `finished_at` of the newest *completed* run, so its age says how old a result
  is — not how long anything has been running. The footer said "has not
  completed in over N minutes", which reads as a run in flight, and the line
  above it asserted "Analysis is running now" whether or not anything was.

  The cost was a wrong investigation: an agent told to treat a wedged analyzer
  as failing went looking for one and found a run that had completed in under
  three minutes, thirty-eight minutes earlier. Waiting is right when something
  is running and never right when nothing is, so the advice has to key off the
  fact that decides it.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem

  defp problem(source) do
    %Problem{
      source: source,
      severity: :error,
      file_path: "lib/a.ex",
      line: 1,
      message: "a finding"
    }
  end

  defp footer(opts) do
    Problems.render_stop_response(
      [problem("exunit")],
      [],
      Keyword.merge([stale_sources: ["exunit"]], opts)
    )
  end

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 60, :second)

  test "an old result with nothing running says so, and does not call it incomplete" do
    text = footer(last_ran: %{"exunit" => minutes_ago(38)}, in_flight: [])

    assert text =~ "38 minutes old"
    assert text =~ "no rerun is running"

    refute text =~ "has not completed in",
           "that wording sends the reader looking for a wedged run; the run finished, " <>
             "the result is simply old"
  end

  # The opposite case, and the one that must not be told to give up.
  test "a rerun in flight says to wait, whatever the age" do
    text = footer(last_ran: %{"exunit" => minutes_ago(38)}, in_flight: ["exunit"])

    assert text =~ "rerun is in flight"
    assert text =~ "stop again"

    refute text =~ "treat the analyzer as failing",
           "something is running; telling the agent to report a failure wastes the rerun"
  end

  test "a fresh result with nothing running does not claim a rerun exists" do
    text = footer(last_ran: %{"exunit" => minutes_ago(1)}, in_flight: [])

    assert text =~ "No rerun is in flight"

    refute text =~ "Analysis is running now",
           "the old footer asserted this unconditionally — it was false whenever the " <>
             "queue was empty"
  end

  test "a source in flight is named, so the claim is checkable" do
    text = footer(last_ran: %{"exunit" => minutes_ago(2)}, in_flight: ["exunit", "credo"])

    assert text =~ "exunit"
  end
end
