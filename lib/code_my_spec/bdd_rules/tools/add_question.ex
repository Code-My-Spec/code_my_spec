defmodule CodeMySpec.BddRules.Tools.AddQuestion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper
  alias CodeMySpec.Questions

  @impl true
  def name, do: "add_question"

  @impl true
  def description do
    """
    Adds a Question (red card) to a story during a Three Amigos session.

    Use when neither the agent nor the PM can answer something in the
    moment — park it, don't let it derail the conversation. Open
    questions count against the readiness gate (`scenarios > questions`);
    call `resolve_question` when the answer is found.
    """
  end

  @impl true
  def params do
    %{
      text:
        {:required,
         {:meta, :string,
          [
            description:
              "The open question in plain language (e.g., 'Does suspension affect mid-transaction cards or only new transactions?'). 1–2000 characters."
          ]}},
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- Stories.fetch_story_by_number(scope, get_param(params, :story_number)),
         {:ok, question} <-
           Questions.create_question(scope, story.id, %{
             text: get_param(params, :text)
           }) do
      BddRulesMapper.question_response(question)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        BddRulesMapper.validation_error(changeset)

      {:error, reason} ->
        BddRulesMapper.error(reason)
    end
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
