defmodule CodeMySpec.Problems.InFlightProgressTest do
  @moduledoc """
  Two stops inside one run's window must not read as a loop.

  `020f573e`. The hook says "a rerun is in flight now — stop again and let it
  replace these". Taking that advice promptly returned the same block
  byte-for-byte, because the promised run was still running and the answer was
  still built from the snapshot before it. Measured on the incident:

      08:13:41.285  stop fires, starts credo run 2963
      08:13:41.663  blocks: "stale, last ran 13m ago … a rerun is in flight"
      08:13:54.585  stop fires again — the advice, taken 13s later
      08:13:57.256  identical text, identical age
      08:13:59.766  run 2963 completes clean

  Nothing was broken: the advice was true and the rerun did replace the
  findings. But two identical blocks in a row is the signature of the livelock
  `1f60a145` was about, where the promised rerun never came — and the correct
  response to that is the opposite of the correct response here. Distinguishing
  them cost three database queries.

  So the footer has to carry something that moves while the run does.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.{Problem, ProblemRenderer}

  defp problem do
    %Problem{
      source: "credo",
      severity: :error,
      file_path: "lib/code_my_spec/invitations/invitation_repository.ex",
      line: 8,
      message: "The alias `CodeMySpec.Repo` is not alphabetically ordered among its group."
    }
  end

  defp render(running_for_seconds, opts \\ []) do
    started_at = DateTime.add(DateTime.utc_now(), -running_for_seconds, :second)

    ProblemRenderer.render_stop_response(
      [problem()],
      [],
      stale_sources: ["credo"],
      last_ran: %{"credo" => DateTime.add(DateTime.utc_now(), -13 * 60, :second)},
      run_duration: Keyword.get(opts, :run_duration, %{"credo" => 18}),
      in_flight: ["credo"],
      in_flight_since: Keyword.get(opts, :since, %{"credo" => started_at}),
      tracked?: true
    )
  end

  test "the message moves while the run does" do
    first = render(0)
    second = render(13)

    assert first =~ "rerun is in flight"
    assert second =~ "rerun is in flight"

    refute first == second,
           "identical text on consecutive stops is what reads as a livelock — " <>
             "the whole reason this footer needed anything new"
  end

  test "it says how long the run has been going and how long that usually takes" do
    assert render(13) =~ "credo, running 13s of a typical 18s"
  end

  # The advice itself was never wrong, and an agent that has learned to trust it
  # should still find it here.
  test "it still says to stop again and let the rerun replace these" do
    assert render(13) =~ "stop again and let it replace these"
  end

  # A source that has never completed a run has no typical duration to compare
  # against. Elapsed alone still moves, which is what this is for.
  test "with no typical duration it reports the elapsed time alone" do
    text = render(13, run_duration: %{})

    assert text =~ "credo, running 13s)"
    refute text =~ "typical"
  end

  # Locally executed projects report which sources are running but not since
  # when. The sentence has to survive that rather than render "running s".
  test "with no start time it falls back to the sentence as it was" do
    text = render(13, since: %{})

    assert text =~ "A rerun is in flight now (credo) — stop again"
    refute text =~ "running"
  end
end
