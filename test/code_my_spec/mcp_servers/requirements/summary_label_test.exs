defmodule CodeMySpec.McpServers.Requirements.SummaryLabelTest do
  @moduledoc """
  What the requirements summary is counting, said in the output.

  Unfiltered, `list_requirements(summary: true)` counts every requirement —
  satisfied and not. On this project that renders `implementation_file: 900`,
  which reads as 900 pieces of outstanding work and is in fact 900 satisfied
  ones. With `status: "unsatisfied"` the same project totals 55.

  The tool's moduledoc claimed the unfiltered default was "aggregate counts of
  unsatisfied requirements", so the number and its description agreed with each
  other and not with the code. I read 900, believed it, and started looking for
  a regression I had caused — the counts are the first thing an agent sees after
  `get_next_requirement`, and nothing in them says which question was answered.

  So the header now names the omission, and this pins it: a count that cannot
  say what it counted is the same class of defect as a check whose message
  argues for a different rule.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper

  defp node(name, satisfied?), do: %{name: name, satisfied: satisfied?}

  defp opts(overrides) do
    Enum.into(overrides, %{
      status: nil,
      entity_type: nil,
      requirement_name: nil,
      module_filter: nil,
      diagnostic: false
    })
  end

  defp render(nodes, overrides) do
    nodes
    |> RequirementsMapper.requirements_summary_response(opts(overrides))
    |> then(& &1.content)
    |> Enum.map_join(" ", &Map.get(&1, "text", ""))
  end

  test "an unfiltered summary says it counted all statuses, and how to ask otherwise" do
    text = render([node("implementation_file", true), node("qa_complete", false)], [])

    assert text =~ "all statuses",
           "the counts read as outstanding work; unfiltered they are not"

    assert text =~ ~s(status: \"unsatisfied\"),
           "naming the omission without naming the remedy leaves the reader where they were"
  end

  # With the filter present the header already prints `status=…`, so a second
  # label would be noise on the one call that was asked correctly.
  test "a filtered summary does not repeat itself" do
    text = render([node("qa_complete", false)], status: "unsatisfied")

    assert text =~ "status=`unsatisfied`"
    refute text =~ "all statuses"
  end

  test "the counts themselves are unchanged" do
    text =
      render(
        [
          node("implementation_file", true),
          node("implementation_file", true),
          node("qa_complete", false)
        ],
        []
      )

    assert text =~ "**implementation_file**: 2"
    assert text =~ "**qa_complete**: 1"
  end
end
