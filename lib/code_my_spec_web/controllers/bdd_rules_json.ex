defmodule CodeMySpecWeb.BddRulesJSON do
  alias CodeMySpec.BddRules.Rule

  def index(%{rules: rules}) do
    %{data: Enum.map(rules, &data/1)}
  end

  def show(%{rule: rule}) do
    %{data: data(rule)}
  end

  defp data(%Rule{} = rule) do
    %{
      id: rule.id,
      account_id: rule.account_id,
      project_id: rule.project_id,
      story_id: rule.story_id,
      statement: rule.statement,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end
end
