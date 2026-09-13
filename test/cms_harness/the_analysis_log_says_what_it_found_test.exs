defmodule CmsHarness.TheAnalysisLogSaysWhatItFoundTest do
  @moduledoc """
  A finished analyzer run logs what it found, not only how long it took.

  Issue `9afcbbdf`. The line read

      [CmsHarness] exunit [] in <root> took 418381ms

  and the `[]` is `inspect(args)` — it says the run took no arguments. Nothing
  in it reports findings, so a run that found twelve failures and a run that
  found none were indistinguishable.

  Tracing a refused promotion on 2026-09-13 I read eight of these as "clean",
  concluded two checkouts were green, and spent four hours on the wrong theory
  while one of them was carrying a regression of mine. `harness.log` is the
  first place anybody looks, and it was the one place that could not answer.

  Asserted on `describe_outcome/1` rather than by capturing a log line: what can
  regress is the summary, and `run/3` shells out to a real analyzer.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Analysis

  test "a run with findings says how many" do
    outcome =
      Analysis.describe_outcome(
        {:ok, %{"source" => "exunit", "exit_status" => 1, "diagnostics" => [%{}, %{}, %{}]}}
      )

    assert outcome =~ "3 finding(s)",
           "the count is the whole point — without it the line cannot be read as a result"

    assert outcome =~ "exit 1"
  end

  test "and a clean run says zero rather than staying silent" do
    outcome =
      Analysis.describe_outcome(
        {:ok, %{"source" => "credo", "exit_status" => 0, "diagnostics" => []}}
      )

    assert outcome =~ "0 finding(s)", """
    A clean run has to say so out loud. "No findings mentioned" was exactly the
    old behaviour, and it is what made a failing run look identical to this one.
    """
  end

  # "Nothing found" and "nothing reported" are the distinction `execution_status`
  # exists for, and flattening them here would undo it.
  test "a source that reported no diagnostics at all is not rendered as zero" do
    outcome = Analysis.describe_outcome({:ok, %{"source" => "compiler", "exit_status" => 0}})

    refute outcome =~ "0 finding(s)",
           "a run that reported nothing is being shown as a run that found nothing"

    assert outcome =~ "no diagnostics reported"
  end

  test "a failed run says so instead of looking like a quiet one" do
    outcome = Analysis.describe_outcome({:error, :harness_disconnected})

    assert outcome =~ "failed",
           "three stranded runs logged the same shape as three clean ones on the day this was written"

    assert outcome =~ "harness_disconnected"
  end

  test "a long failure reason does not run away with the line" do
    outcome = Analysis.describe_outcome({:error, String.duplicate("x", 5_000)})

    assert String.length(outcome) < 200,
           "one run's error would push everything else out of a reader's window"
  end
end
