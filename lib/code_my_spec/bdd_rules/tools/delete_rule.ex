defmodule CodeMySpec.BddRules.Tools.DeleteRule do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.BddRules
  alias CodeMySpec.Files
  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper

  @impl true
  def name, do: "delete_rule"

  @impl true
  def description do
    """
    Deletes a Rule (blue card) from a Three Amigos story. Cascade-removes any
    linked scenarios (Criteria linked via `rule_id`) in the same transaction.
    Use this for PM-side cleanup of bogus or superseded rules.
    """
  end

  @impl true
  def params do
    %{rule_id: {:required, {:meta, :string, [description: "UUID of the rule to delete."]}}}
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, rule} <- fetch_rule(scope, get_param(params, :rule_id)),
         tracked = Files.tracked_in_project(scope, BddRules.claimed_spec_paths(rule)),
         {:ok, deleted} <- BddRules.delete_rule(scope, rule, tracked) do
      BddRulesMapper.rule_deleted_response(deleted)
    else
      {:error, reason} ->
        BddRulesMapper.error(reason)
    end
  end

  defp fetch_rule(scope, id) when is_binary(id) and id != "" do
    case BddRules.get_rule(scope, id) do
      nil -> {:error, :rule_not_found}
      rule -> {:ok, rule}
    end
  end

  defp fetch_rule(_scope, _id), do: {:error, "must provide rule_id"}

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
