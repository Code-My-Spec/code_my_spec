defmodule CodeMySpec.McpServers.BddRules.Tools.UpdateRule do
  @moduledoc """
  Updates a Rule's (blue card) statement during a Three Amigos session.
  Use this for PM-side wording fixes on an existing rule without
  re-creating it or losing its linked scenarios.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.BddRules
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :rule_id, :string, required: true, doc: "UUID of the rule to update."

    field :statement, :string,
      required: true,
      doc:
        "The new rule statement in business terms (e.g., 'Suspended cards cannot be used for purchases'). 1–1000 characters."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, rule} <- fetch_rule(scope, get_param(params, :rule_id)),
         {:ok, updated} <-
           BddRules.update_rule(scope, rule, %{statement: get_param(params, :statement)}) do
      {:reply, BddRulesMapper.rule_updated_response(updated), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, BddRulesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, BddRulesMapper.error(reason), frame}
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
