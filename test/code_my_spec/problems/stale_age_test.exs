defmodule CodeMySpec.Problems.StaleAgeTest do
  @moduledoc """
  A stale source says how long it has been stale, and the advice follows.

  "Stale — stop again and let the rerun replace these" is right for a source
  mid-cycle and wrong for one that has not completed in half an hour, and the
  message gave the same instruction either way. That is how five consecutive
  stops went by on a finding already fixed and pushed: each stop said to wait,
  each rerun was queued behind a 2m35s spex sweep, and nothing in the wording
  distinguished "a rerun is coming" from "no rerun can land".

  Those two need opposite responses — wait, or stop editing and report the
  analyzer — so the age is what makes the message actionable.
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

  defp render(seconds_ago) do
    ProblemRenderer.render_stop_response([problem("credo")], [],
      stale_sources: ["credo"],
      last_ran: %{"credo" => DateTime.add(DateTime.utc_now(), -seconds_ago, :second)}
    )
  end

  test "a source stale for a couple of minutes says so and says to wait" do
    out = render(120)

    assert out =~ "last ran 2m ago"
    assert out =~ "persist across several stops"
    refute out =~ "treat the analyzer as failing"
  end

  test "a source stale for half an hour says to report it instead of waiting" do
    out = render(1_860)

    assert out =~ "last ran 31m ago"

    assert out =~ "treat the analyzer as failing",
           "waiting is the wrong advice once no rerun has landed in longer than " <>
             "a rerun takes — that is the loop this exists to break"
  end

  test "a source that has never completed says that rather than an age" do
    out =
      ProblemRenderer.render_stop_response([problem("credo")], [],
        stale_sources: ["credo"],
        last_ran: %{"credo" => nil}
      )

    assert out =~ "has never completed"
  end

  test "a fresh source carries no stale marker" do
    out = ProblemRenderer.render_stop_response([problem("credo")], [], stale_sources: [])

    refute out =~ "stale"
  end
end
