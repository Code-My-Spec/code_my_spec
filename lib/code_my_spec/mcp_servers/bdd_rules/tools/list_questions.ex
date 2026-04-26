defmodule CodeMySpec.McpServers.BddRules.Tools.ListQuestions do
  @moduledoc """
  Lists every Question on a given story (open, resolved, and deferred),
  ordered by insertion time (oldest first).
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Questions

  schema do
    field :story_id, :integer,
      required: true,
      doc: "ID of the story whose questions should be listed."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        questions = Questions.list_questions_for_story(scope, get_param(params, :story_id))
        {:reply, BddRulesMapper.questions_list_response(questions), frame}

      {:error, reason} ->
        {:reply, BddRulesMapper.error(reason), frame}
    end
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
