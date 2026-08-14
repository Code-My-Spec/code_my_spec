defmodule CodeMySpec.Problems.OvertakenOnArrivalTest do
  @moduledoc """
  "Waiting cannot help" and "waiting is the only thing that helps" must not be
  guessed at from a clock.

  `7a7eed33`. A run is fingerprinted when it is *enqueued* and judged against
  the tree when it is *read*, so an edit landing inside its window makes the
  result stale the instant it arrives. For a slow source that is the normal
  working rhythm — exunit ~2m20s, spex ~2m35s against compiler's 9s — and the
  footer's ordinary advice, stop again and let the rerun replace these, never
  terminates. The report watched it climb 33s, 2m, 5m, 7m, 7m across consecutive
  stops with runs completing throughout.

  The renderer answers that with a different sentence: the analyzer is working,
  it answered about the tree it was given, so either stop editing until a sweep
  lands or act on these one edit behind. Right advice, and it was reached by
  inference — a result younger than the run took *must* have been overtaken.

  That inference is sound only if nothing was edited after the run finished, and
  a stop closely following a long run breaks it: the edit came afterwards, a
  rerun would be clean, and the message told the agent not to bother waiting for
  one. `completed_fingerprint` replaces the inference with the ledger's own
  answer — stamped at reconcile, so it differs from `input_fingerprint` exactly
  when the tree moved while the run was in flight.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.{Problem, ProblemRenderer}

  @overtaken " and your edits landed inside it"
  # The ordinary-lag advice, which is the whole point of not saying the other:
  # stopping again gets a rerun, and that rerun will be current.
  @waiting_works "Stopping again enqueues one"

  defp problem do
    %Problem{
      source: "exunit",
      severity: :error,
      file_path: "test/code_my_spec/thing_test.exs",
      line: 12,
      message: "Assertion with == failed"
    }
  end

  defp render(opts) do
    ProblemRenderer.render_stop_response(
      [problem()],
      [],
      [
        stale_sources: ["exunit"],
        last_ran: %{"exunit" => DateTime.add(DateTime.utc_now(), -10, :second)},
        run_duration: %{"exunit" => 320}
      ] ++ opts
    )
  end

  # The case the duration inference gets wrong. Ten seconds after a 5m20s run,
  # so `age < duration` says overtaken — but the ledger says the run's inputs
  # never moved under it, which means the edit came after it finished and a
  # rerun will be clean.
  test "an edit made after the run finished is an ordinary lag" do
    text = render(overtaken: %{"exunit" => false})

    refute text =~ @overtaken,
           "telling the agent a rerun will finish stale too, when it will not, " <>
             "sends it to act on findings it could simply have waited out"

    assert text =~ @waiting_works
  end

  test "an edit made during the run is still called out" do
    text = render(overtaken: %{"exunit" => true})

    assert text =~ @overtaken
    assert text =~ "answered about the tree it was given"
  end

  # The property the whole issue is about, and the one thing nothing asserted:
  # the advice has to have an ending. A source slower than the edit cadence can
  # never go fresh, so "stop again and let the rerun replace these" is an
  # instruction to keep doing something that cannot work — five consecutive
  # stops, escaped only by clearing the stored problems by hand.
  #
  # An agent reads this to decide between two actions, so it is not enough that
  # the text be accurate: it has to name the move that terminates. Waiting is
  # offered too, and correctly — a sweep with no editing during it does land
  # clean — but acting on findings one edit behind must be on the table, because
  # it is the only option that does not depend on the agent stopping work.
  test "when waiting cannot help, acting on them is offered as a way out" do
    text = render(overtaken: %{"exunit" => true})

    assert text =~ "act on these as they stand",
           "the message says a rerun will finish stale as well and then leaves " <>
             "the agent nothing to do but rerun. That is the non-terminating " <>
             "loop this branch exists to break, restored by omission."

    assert text =~ "one edit behind is not the same as wrong",
           "acting on a stale finding needs a reason, or an agent that has been " <>
             "taught to respect the stale marker will not do it"
  end

  # Runs that finished before the column existed have no answer, and guessing
  # "not overtaken" for them would restore the non-terminating advice this whole
  # branch exists to break. So they keep the inference.
  test "a run with no recorded answer falls back to comparing age to duration" do
    assert render(overtaken: %{}) =~ @overtaken
    assert render(overtaken: %{"exunit" => nil}) =~ @overtaken
  end

  # And the fallback still distinguishes: a result older than the run took was
  # not overtaken by anything, it is simply behind.
  test "the fallback does not fire on a result older than its own run" do
    text =
      ProblemRenderer.render_stop_response([problem()], [],
        stale_sources: ["exunit"],
        last_ran: %{"exunit" => DateTime.add(DateTime.utc_now(), -900, :second)},
        run_duration: %{"exunit" => 320},
        overtaken: %{}
      )

    refute text =~ @overtaken
  end
end
