defmodule CodeMySpec.Problems.ReproduceCommandTest do
  @moduledoc """
  A blocking credo group says how to reproduce it.

  `mix credo` prints "Showing priority issues: ↑ ↗ →" and suppresses the ↓ ↘
  band. The analyzer runs `--all --all-priorities` and reports all of it, and
  `block_changed` promotes those low-priority findings to blocking the moment
  they sit in a file the session touched. So the obvious way to check before
  stopping returns green on exactly the findings that will block:

      mix credo <file>                                  → 0
      mix credo suggest --all --all-priorities <file>   → 2

  Measured on `spec_projector_test.exs:4` and
  `agent_tasks/context_design_review.ex:20`. Five findings blocked a stop of
  mine that way, one of them recorded two days before I opened the file.

  The gate knows what it ran. Printing it turns an unverifiable block into a
  one-command check, which is the difference between fixing the finding and
  stopping again to find out whether you did.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.ProblemRenderer
  alias CodeMySpec.StaticAnalysis.CredoRun

  defp problem(source) do
    %CodeMySpec.Problems.Problem{
      source: source,
      severity: :info,
      file_path: "lib/a.ex",
      line: 1,
      message: "something low priority",
      category: "x"
    }
  end

  defp render(source, opts \\ []) do
    ProblemRenderer.render_stop_response([problem(source)], [], opts)
  end

  test "the credo group carries the command that reproduces it" do
    out = render("credo", reproduce_commands: %{"credo" => CredoRun.reproduce_command()})

    assert out =~ "--all-priorities",
           "plain `mix credo` hides this band; naming the flags is the whole point"

    assert out =~ "mix credo suggest"
  end

  test "the command comes from the same list the analyzer runs" do
    # Not a second copy of the flags. The two that decide which findings appear
    # are the ones that matter, and they are read off the analyzer's own args
    # rather than retyped here — a drifted hint is worse than none, because it
    # would be confidently wrong.
    command = CredoRun.reproduce_command()

    assert command =~ "--all"
    assert command =~ "--all-priorities"

    refute command =~ "--format",
           "format flags change the output shape, not which findings exist, and " <>
             "pasting json at a human is not a reproduction"
  end

  test "a source with no command renders exactly as before" do
    assert render("exunit", reproduce_commands: %{"credo" => "x"}) ==
             render("exunit")
  end

  test "no commands at all renders exactly as before" do
    assert render("credo", reproduce_commands: %{}) == render("credo")
  end
end
