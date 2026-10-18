defmodule CodeMySpec.BddRules.Tools.UpdateRule do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper

  @impl true
  def name, do: "update_rule"

  @impl true
  def description do
    """
    Updates a Rule's (blue card) statement during a Three Amigos session.
    Use this for PM-side wording fixes on an existing rule without
    re-creating it or losing its linked scenarios.
    """
  end

  @impl true
  def params do
    %{
      rule_id: {:required, {:meta, :string, [description: "UUID of the rule to update."]}},
      statement:
        {:required,
         {:meta, :string,
          [
            description:
              "The new rule statement in business terms (e.g., 'Suspended cards cannot be used for purchases'). 1–1000 characters."
          ]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, rule} <- fetch_rule(scope, get_param(params, :rule_id)),
         {:ok, updated} <-
           BddRules.update_rule(scope, rule, %{statement: get_param(params, :statement)}) do
      BddRulesMapper.rule_updated_response(updated)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        BddRulesMapper.validation_error(changeset)

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
