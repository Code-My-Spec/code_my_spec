defmodule CodeMySpec.Problems.TheStopHookPointsAtListProblemsTest do
  @moduledoc """
  A coding agent tapped out against a stop hook carrying thirty exunit problems.

  Two things were wrong: it listed ten per source, which is most of a turn's
  context spent on text the agent then re-reads, and the overflow told it to
  "use get_issue to inspect" — a tool that answers about issues, not problems,
  so the one next step offered did not exist.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemRenderer

  defp problems(n, source) do
    for i <- 1..n do
      struct(Problem, %{
        severity: :error,
        source_type: :test,
        source: source,
        file_path: "test/my_app/thing_#{i}_test.exs",
        line: i,
        message: "assertion failed #{i}",
        category: "test",
        project_id: Ecto.UUID.generate()
      })
    end
  end

  test "the overflow names list_problems with the source, not get_issue" do
    text = ProblemRenderer.render_stop_response(problems(30, "exunit"), [])

    assert text =~ "list_problems", """
    The overflow has to name the tool that can answer. It said "use get_issue to
    inspect", which answers about issues rather than problems.
    """

    assert text =~ ~s(source = "exunit"),
           "the hint should carry the source, so the agent does not have to guess it"

    refute text =~ "get_issue", "get_issue cannot answer about problems"
  end

  test "the full count is still stated even though few are listed" do
    text = ProblemRenderer.render_stop_response(problems(30, "exunit"), [])

    assert text =~ "exunit (30)",
           "progressive disclosure means showing fewer, not hiding how many there are"
  end

  # Ten, because story 554's criterion 5094 pins it. Asserted here so that
  # whoever changes it has to change this too, and finds 5094 while doing so.
  test "the inline list is capped per source" do
    text = ProblemRenderer.render_stop_response(problems(30, "exunit"), [])
    listed = text |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "  - "))

    assert listed == 10, "listed #{listed} inline; criterion 5094 pins ten per source"
  end
end
