defmodule CodeMySpec.McpServers.MainAgent.Tools.SearchAnswers do
  @moduledoc """
  Decisions the user has already made, matching some words.

  Look here before escalating. A question they have answered before does not
  need asking again — pass the id to `answer_question` as `precedent_id` with
  basis `precedent`.

  Answered questions only. An open one matching the same words is the opposite
  of a precedent: evidence that this has been asked and not decided.
  """

  # The match is on the question's text, because that is all the main agent has
  # to go on when a new one arrives. It returns *similar* by construction, which
  # is why `answer_question` checks the precedent rather than trusting it — the
  # more useful this search is, the more often it hands back an answer to a
  # different question.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.AnswersMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Utils.MapAccess

  schema do
    field :query, :string, required: true, doc: "Words from the question you are handling."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} ->
        {:reply, AnswersMapper.results(MainAgent.search_answers(scope, query(params))), frame}

      {:error, reason} ->
        {:reply, AnswersMapper.error(reason), frame}
    end
  end

  defp query(params), do: MapAccess.get(params, :query)
end
