defmodule CodeMySpec.BddRules.GherkinRenderer do
  @moduledoc """
  Renders a story's Three Amigos artifacts (Story + Rules + Scenarios)
  as a plain-text Gherkin `.feature` document.

  The DB is the source of truth — this module just assembles the view.
  Used by `GetStoryGherkin` MCP tool, the local web UI's feature
  preview, and downstream SexySpex generation.

  Output shape:

      Feature: <story title>
        <story description, indented>

        Rule: <rule statement>

          Scenario: <scenario title>
            <scenario body, indented>

          Scenario: <next scenario title>
            ...

        Rule: <next rule statement>
          ...

  Rules and scenarios are rendered in `inserted_at` order (the canonical
  ordering for Three Amigos artifacts).
  """

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddRules
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @spec render(Scope.t(), Story.t()) :: String.t()
  def render(%Scope{} = scope, %Story{} = story) do
    rules = BddRules.list_rules_for_story(scope, story.id)

    scenarios_by_rule =
      AcceptanceCriteria.list_story_criteria(scope, story.id)
      |> Enum.filter(&(not is_nil(&1.kind)))
      |> Enum.group_by(& &1.rule_id)

    [
      "Feature: #{story.title}",
      indent(story.description || "", 2),
      "",
      Enum.map_join(rules, "\n\n", &render_rule(&1, scenarios_by_rule))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp render_rule(rule, scenarios_by_rule) do
    scenarios = Map.get(scenarios_by_rule, rule.id, [])

    [
      "  Rule: #{rule.statement}",
      "",
      Enum.map_join(scenarios, "\n\n", &render_scenario/1)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp render_scenario(criterion) do
    [
      "    Scenario: #{criterion.description}",
      indent(criterion.body || "", 6)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp indent("", _spaces), do: ""

  defp indent(text, spaces) do
    pad = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end
end
