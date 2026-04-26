defmodule CodeMySpec.McpServers.BddRules.Tools.ResolveQuestion do
  @moduledoc """
  Marks a Question (red card) as resolved.

  Once resolved, the question no longer counts against the readiness
  gate's `scenarios > questions` clause — the record stays for
  historical context but doesn't block the session.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Questions

  schema do
    field :question_id, :string, required: true, doc: "UUID of the question to resolve."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:question, %Questions.Question{} = question} <-
           {:question, Questions.get_question(scope, get_param(params, :question_id))},
         {:ok, resolved} <- Questions.resolve_question(scope, question) do
      {:reply, BddRulesMapper.question_resolved_response(resolved), frame}
    else
      {:question, nil} ->
        {:reply, BddRulesMapper.error(:question_not_found), frame}

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
