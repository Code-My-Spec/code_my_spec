defmodule CodeMySpec.BddRules.Tools.AddScenario do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "add_scenario"

  @impl true
  def description do
    """
    Adds a Scenario (green card) to a story during a Three Amigos session.

    Each scenario is a Criterion record carrying both the title (one-line
    description in domain terms) and the Given/When/Then body (plain
    Gherkin), linked to a Rule via `rule_id`. Rules and scenarios are
    created together as a single atom — there is no two-stage "title now,
    body later" split.

    The scenario's `kind` distinguishes happy-path from failure-path
    coverage. `kind` is metadata for UI grouping and Gherkin rendering;
    the readiness gate only requires ≥1 scenario per rule of any kind.
    """
  end

  @impl true
  def params do
    %{
      title:
        {:required,
         {:meta, :string,
          [
            description:
              "Scenario title (one-line, in domain language; names the persona with relevant context)."
          ]}},
      body:
        {:required,
         {:meta, :string,
          [description: "Plain-text Gherkin Given/When/Then body for the scenario."]}},
      kind:
        {:required,
         {:meta, :string,
          [
            description:
              "`happy_path` or `failure_path`. Use `happy_path` for the normal flow; add `failure_path` only when a genuine failure surface exists for this rule."
          ]}},
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}},
      rule_statement:
        {:required,
         {:meta, :string,
          [
            description:
              "The exact statement of the Rule this scenario illustrates. The Rule must already exist on the story."
          ]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- Stories.fetch_story_by_number(scope, get_param(params, :story_number)),
         {:ok, rule} <-
           find_rule_by_statement(scope, story.id, get_param(params, :rule_statement)),
         {:ok, kind} <- parse_kind(get_param(params, :kind)),
         {:ok, criterion} <-
           AcceptanceCriteria.create_criterion(scope, story, %{
             description: get_param(params, :title),
             body: get_param(params, :body),
             kind: kind,
             rule_id: rule.id
           }) do
      BddRulesMapper.scenario_response(criterion)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        BddRulesMapper.validation_error(changeset)

      {:error, reason} ->
        BddRulesMapper.error(reason)
    end
  end

  defp find_rule_by_statement(scope, story_id, statement) do
    rules = BddRules.list_rules_for_story(scope, story_id)

    case Enum.find(rules, &(&1.statement == statement)) do
      nil -> {:error, :rule_not_found}
      rule -> {:ok, rule}
    end
  end

  defp parse_kind("happy_path"), do: {:ok, :happy_path}
  defp parse_kind("failure_path"), do: {:ok, :failure_path}
  defp parse_kind(_), do: {:error, :invalid_kind}

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
