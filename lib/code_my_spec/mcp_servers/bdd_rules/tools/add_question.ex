defmodule CodeMySpec.McpServers.BddRules.Tools.AddQuestion do
  @moduledoc """
  Adds a Question (red card) to a story during a Three Amigos session.

  Use when neither the agent nor the PM can answer something in the
  moment — park it, don't let it derail the conversation. Open
  questions count against the readiness gate (`scenarios > questions`);
  call `resolve_question` when the answer is found.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Questions

  schema do
    field :story_id, :integer, required: true, doc: "ID of the story to add the question to."

    field :text, :string,
      required: true,
      doc:
        "The open question in plain language (e.g., 'Does suspension affect mid-transaction cards or only new transactions?'). 1–2000 characters."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, question} <-
           Questions.create_question(scope, get_param(params, :story_id), %{
             text: get_param(params, :text)
           }) do
      {:reply, BddRulesMapper.question_response(question), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, BddRulesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, BddRulesMapper.error(reason), frame}
    end
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
