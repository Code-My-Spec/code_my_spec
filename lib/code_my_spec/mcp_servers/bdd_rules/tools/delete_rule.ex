defmodule CodeMySpec.McpServers.BddRules.Tools.DeleteRule do
  @moduledoc """
  Deletes a Rule (blue card) from a Three Amigos story. Cascade-removes any
  linked scenarios (Criteria linked via `rule_id`) in the same transaction.
  Use this for PM-side cleanup of bogus or superseded rules.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.BddRules
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :rule_id, :string, required: true, doc: "UUID of the rule to delete."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, rule} <- fetch_rule(scope, get_param(params, :rule_id)),
         {:ok, deleted} <- BddRules.delete_rule(scope, rule) do
      {:reply, BddRulesMapper.rule_deleted_response(deleted), frame}
    else
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
