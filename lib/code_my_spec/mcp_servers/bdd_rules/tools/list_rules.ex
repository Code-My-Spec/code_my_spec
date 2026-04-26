defmodule CodeMySpec.McpServers.BddRules.Tools.ListRules do
  @moduledoc """
  Lists every Rule on a given story, ordered by insertion time
  (oldest first).
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.BddRules
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :integer,
      required: true,
      doc: "ID of the story whose rules should be listed."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      rules = BddRules.list_rules_for_story(scope, get_param(params, :story_id))
      {:reply, BddRulesMapper.rules_list_response(rules), frame}
    else
      {:error, reason} ->
        {:reply, BddRulesMapper.error(reason), frame}
    end
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
