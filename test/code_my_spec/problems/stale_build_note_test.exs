defmodule CodeMySpec.Problems.StaleBuildNoteTest do
  @moduledoc """
  "Stop again and let a rerun replace these" is wrong when the rerun runs the
  same old code, and the stop response could not say so.

  `d9f0846c`. A harness runs the analyzer it booted with, so a fix to
  `StaticAnalysis` is not in force until the harness is rebuilt. Measured:
  `be9a46f8` landed mid-afternoon while the harness's compiled
  `StaticAnalysis.Pipeline.beam` was from the previous day, eleven commits
  behind, for an entire session — and three stop-hook loops were spent on
  findings that were already fixed.

  What made it expensive is that it renders identically to an ordinary stale
  finding, and identically to the real defect it was masking. Each loop the
  visible symptom matched a bug that existed, so the diagnosis stopped there.
  Recovering it needed a `.beam` timestamp, which nobody thinks to check while
  being told a rerun is in flight.

  The harness computes this — only it can compare its own boot sha against its
  own checkout — stamps it on the run, and this is the far end: that it reaches
  the response the agent actually reads.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.{Problem, ProblemRenderer}

  defp problem(source) do
    %Problem{source: source, severity: :error, file_path: "lib/a.ex", line: 1, message: "boom"}
  end

  defp render(opts) do
    ProblemRenderer.render_stop_response([problem("credo")], [], opts)
  end

  @note "this result came from a build at abc1234; the checkout is now at def5678, " <>
          "and that range changed analyzer code — rebuild the harness (`just refresh`)"

  test "says when the build that produced a finding is behind the tree" do
    text = render(analyzer_staleness: %{"credo" => @note})

    assert text =~ "Analyzer build:"
    assert text =~ "abc1234"

    assert text =~ "just refresh",
           "the remedy is a rebuild, and it is not one an agent guesses from " <>
             "'stale' — three loops went by without it"
  end

  test "says nothing when the build is current" do
    text = render(analyzer_staleness: %{})

    refute text =~ "Analyzer build:",
           "a note on every stop is noise, and noise is why nobody reads the " <>
             "ones that matter"
  end

  test "says nothing when the caller does not supply the field at all" do
    refute render([]) =~ "Analyzer build:"
  end

  # Per source, not per sweep: one analyzer can be behind while another is
  # current, and the advice differs for each.
  test "marks only the source whose run carried the note" do
    text =
      ProblemRenderer.render_stop_response(
        [problem("credo"), problem("exunit")],
        [],
        analyzer_staleness: %{"credo" => @note}
      )

    [credo_section, exunit_section] = String.split(text, "exunit (1)")

    assert credo_section =~ "Analyzer build:"
    refute exunit_section =~ "Analyzer build:"
  end
end
