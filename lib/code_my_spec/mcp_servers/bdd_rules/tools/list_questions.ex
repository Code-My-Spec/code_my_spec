defmodule CodeMySpec.McpServers.BddRules.Tools.ListQuestions do
  @moduledoc """
  Lists every Question on a given story (open, resolved, and deferred),
  ordered by insertion time (oldest first).
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.StoryRefs
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Questions

  schema do
    field :story_number, :integer,
      required: true,
      description: "Story number (list_story_titles shows them)"
  end

  @impl true
  def execute(params, frame) do
    case questions(params, frame) do
      {:ok, questions} -> {:reply, BddRulesMapper.questions_list_response(questions), frame}
      {:error, reason} -> {:reply, BddRulesMapper.error(reason), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(params, frame) do
    with {:ok, questions} <- questions(params, frame) do
      {:ok, Enum.map(questions, &row/1)}
    end
  end

  defp questions(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, story} <- StoryRefs.fetch_story(scope, get_param(params, :story_number)) do
      {:ok, Questions.list_questions_for_story(scope, story.id)}
    end
  end

  defp row(q) do
    %{"id" => q.id, "text" => q.text, "status" => to_string(q.status), "resolution" => q.resolution}
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
