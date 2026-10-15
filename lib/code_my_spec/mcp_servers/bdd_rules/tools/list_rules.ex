defmodule CodeMySpec.McpServers.BddRules.Tools.ListRules do
  @moduledoc """
  Lists every Rule on a given story, ordered by insertion time
  (oldest first).
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.BddRules
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.StoryRefs
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_number, :integer,
      required: true,
      description: "Story number (list_story_titles shows them)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, story} <- StoryRefs.fetch_story(scope, get_param(params, :story_number)) do
      rules = BddRules.list_rules_for_story(scope, story.id)
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
