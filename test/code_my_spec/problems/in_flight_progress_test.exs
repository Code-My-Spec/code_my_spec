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
      tracked?: true,
      working_copy_id: Keyword.get(opts, :working_copy_id)
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

  # The advice used to be "stop again and let it replace these", and taking it
  # promptly is what 5e9fa939 measured: three consecutive blocked stops while
  # the run grew 0s → 4m42s → 5m15s. A stop is the thing being refused, so the
  # agent re-stops immediately, lands inside the same run, and is told the same
  # thing. Now it is offered a wait that outlasts the run instead.
  test "it offers a wait that outlasts the run, not another stop into it" do
    text = render(13, working_copy_id: "h-abc")

    assert text =~ "analysis/wait",
           "a stop is what is being refused, so 'stop again' races the run and loses"

    assert text =~ "localhost:4004/api/harnesses/h-abc/analysis/wait"

    assert text =~ "background",
           "a sweep is 200-590s; a foreground curl would hit the agent's own timeout"
  end

  # No harness, no URL to offer — the same rule `Hooks.Stop.wait_directive/1`
  # follows. A 404 dressed as a remedy is worse than plain instructions.
  test "without a harness it says to wait without naming an endpoint" do
    text = render(13)

    assert text =~ "Let it finish, then stop again"
    refute text =~ "analysis/wait"
    refute text =~ "localhost"
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

    assert text =~ "A rerun is in flight now (credo)."
    refute text =~ "running"
  end

  # 0e4b35e8. `started_at` is stamped at enqueue, not at execution, and the
  # harness runs analyzers one at a time — so a source waiting its turn was
  # rendered as one that had been running the whole time. Reported as "credo,
  # running 20s of a typical 9s": an analyzer at more than double its normal
  # runtime, which is the signature of a stuck process. Nothing was stuck. credo
  # was behind a 198-second spex sweep and took 8 seconds once it started.
  describe "when one analyzer is waiting on another" do
    defp render_queue(spex_elapsed, credo_elapsed) do
      now = DateTime.utc_now()

      ProblemRenderer.render_stop_response(
        [problem()],
        [],
        stale_sources: ["credo"],
        last_ran: %{"credo" => DateTime.add(now, -13 * 60, :second)},
        run_duration: %{"credo" => 9, "spex" => 198},
        in_flight: ["credo", "spex"],
        in_flight_since: %{
          "spex" => DateTime.add(now, -spex_elapsed, :second),
          "credo" => DateTime.add(now, -credo_elapsed, :second)
        },
        tracked?: true
      )
    end

    test "the blocker is named, with the progress that says how long to wait" do
      assert render_queue(60, 20) =~ "queued behind spex, running 1m of a typical 3m18s"
    end

    test "the one still waiting is named as queued, not as running" do
      text = render_queue(60, 20)

      assert text =~ "credo has not started"

      refute text =~ "credo, running",
             "a queued analyzer reported as running invites exactly the wrong " <>
               "diagnosis: 20s against a typical 9s reads as a hung process, and " <>
               "the reader goes looking for one that does not exist"
    end

    test "the running figure still moves, so two stops do not read as a livelock" do
      refute render_queue(60, 20) == render_queue(73, 33)
    end
  end
end
