defmodule CodeMySpec.Problems.KilledProcessNoticeTest do
  @moduledoc """
  A suite that was killed is not a suite that failed, and the footer has to say
  which.

  `0bc611c9`. `** (EXIT from #PID<…>) killed` is a process being terminated —
  never an assertion — so a run cut short under load arrives looking exactly
  like a run that found real defects. Measured over four consecutive stops:
  twelve distinct findings, a different set each sweep including a different
  line of the same file, every one passing standalone in seconds.

  What makes it expensive is that the advice is *correct*. "Stop again and let
  the rerun replace these" does work — the rerun lands, `exunit` goes fresh, and
  it replaces them with another random set. Followed as instructed it blocks
  every couple of minutes indefinitely, and the only exit is `clear_problems`,
  which requires already knowing what `killed` means.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.{Problem, ProblemRenderer}

  @notice "killed processes, not assertions"

  defp killed(file, line) do
    %Problem{
      source: "exunit",
      severity: :error,
      file_path: file,
      line: line,
      message: "** (EXIT from #PID<0.16673.0>) killed"
    }
  end

  defp real(file, line) do
    %Problem{
      source: "exunit",
      severity: :error,
      file_path: file,
      line: line,
      message: "Assertion with == failed"
    }
  end

  defp render(problems), do: ProblemRenderer.render_stop_response(problems, [])

  test "a group of nothing but killed processes says so" do
    text = render([killed("test/a_test.exs", 12), killed("test/b_test.exs", 40)])

    assert text =~ @notice,
           "twelve phantom findings across four stops read as real failures, " <>
             "and the correct advice — stop again — produced a fresh block each " <>
             "time. Nothing in the footer distinguished a terminated suite from " <>
             "a failing one."

    assert text =~ "clear these rather than editing anything",
           "an agent that believes these are real edits code that is not broken"
  end

  test "one killed process beside a real failure says nothing" do
    text = render([killed("test/a_test.exs", 12), real("test/b_test.exs", 40)])

    refute text =~ @notice,
           "a run that mostly worked is not environmental, and calling it so " <>
             "hides the failure that is genuinely there"
  end

  test "ordinary failures are untouched" do
    text = render([real("test/a_test.exs", 12), real("test/b_test.exs", 40)])

    refute text =~ @notice
  end

  test "the count in the notice is the number of findings" do
    text = render([killed("test/a_test.exs", 12), killed("test/b_test.exs", 40)])

    assert text =~ "all 2 are killed processes"
  end

  test "a single finding reads as one, not as \"all 1\"" do
    text = render([killed("test/a_test.exs", 12)])

    assert text =~ "this is a killed process, not an assertion"

    refute text =~ "all 1",
           "counting without reading. This lands in front of every agent that " <>
             "hits a one-finding block, which is the common case."
  end
end
