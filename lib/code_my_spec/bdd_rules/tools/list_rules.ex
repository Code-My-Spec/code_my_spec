defmodule CodeMySpec.BddRules.Tools.ListRules do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper

  @impl true
  def name, do: "list_rules"

  @impl true
  def description do
    """
    Lists every Rule on a given story, ordered by insertion time
    (oldest first).
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    case rules(params, context) do
      {:ok, rules} -> BddRulesMapper.rules_list_response(rules)
      {:error, reason} -> BddRulesMapper.error(reason)
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, rules} <- rules(params, context) do
      {:ok, Enum.map(rules, &row/1)}
    end
  end

  # Lifted out of `execute/2` so both paths run the same query.
  defp rules(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- Stories.fetch_story_by_number(scope, get_param(params, :story_number)) do
      {:ok, BddRules.list_rules_for_story(scope, story.id)}
    end
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  # String keys and plain values: these cross into a Lua VM, where an atom key
  # and a struct are not things that exist.
  defp row(rule) do
    %{
      "id" => rule.id,
      "story_id" => rule.story_id,
      "statement" => rule.statement
    }
  end
end
