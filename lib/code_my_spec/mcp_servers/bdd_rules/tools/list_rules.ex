defmodule CodeMySpec.McpServers.BddRules.Tools.ListRules do
  @moduledoc """
  Lists every Rule on a given story, ordered by insertion time
  (oldest first).
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

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
    case rules(params, frame) do
      {:ok, rules} -> {:reply, BddRulesMapper.rules_list_response(rules), frame}
      {:error, reason} -> {:reply, BddRulesMapper.error(reason), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(params, frame) do
    with {:ok, rules} <- rules(params, frame) do
      {:ok, Enum.map(rules, &row/1)}
    end
  end

  # Lifted out of `execute/2` so both paths run the same query.
  defp rules(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, story} <- StoryRefs.fetch_story(scope, get_param(params, :story_number)) do
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
