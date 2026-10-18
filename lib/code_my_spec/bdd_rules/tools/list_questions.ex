defmodule CodeMySpec.BddRules.Tools.ListQuestions do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper
  alias CodeMySpec.Questions

  @impl true
  def name, do: "list_questions"

  @impl true
  def description do
    """
    Lists every Question on a given story (open, resolved, and deferred),
    ordered by insertion time (oldest first).
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
    case questions(params, context) do
      {:ok, questions} -> BddRulesMapper.questions_list_response(questions)
      {:error, reason} -> BddRulesMapper.error(reason)
    end
  end

  @impl true
  def script_result(params, context) do
    with {:ok, questions} <- questions(params, context) do
      {:ok, Enum.map(questions, &row/1)}
    end
  end

  defp questions(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- Stories.fetch_story_by_number(scope, get_param(params, :story_number)) do
      {:ok, Questions.list_questions_for_story(scope, story.id)}
    end
  end

  defp row(q) do
    %{
      "id" => q.id,
      "text" => q.text,
      "status" => to_string(q.status),
      "resolution" => q.resolution
    }
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
