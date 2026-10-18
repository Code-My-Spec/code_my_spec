defmodule CodeMySpec.Agents.Tools.SearchAnswers do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Tools.AnswersResponses, as: AnswersMapper
  alias CodeMySpec.Utils.MapAccess

  @impl true
  def name, do: "search_answers"

  @impl true
  def description do
    """
    Decisions the user has already made, matching some words.

    Look here before escalating. A question they have answered before does not
    need asking again — pass the id to `answer_question` as `precedent_id` with
    basis `precedent`.

    Answered questions only. An open one matching the same words is the opposite
    of a precedent: evidence that this has been asked and not decided.
    """
  end

  @impl true
  def params do
    %{
      query:
        {:required, {:meta, :string, [description: "Words from the question you are handling."]}}
    }
  end

  @impl true
  def call(params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        AnswersMapper.results(MainAgent.search_answers(scope, query(params)))

      {:error, reason} ->
        AnswersMapper.error(reason)
    end
  end

  defp query(params), do: MapAccess.get(params, :query)
end
