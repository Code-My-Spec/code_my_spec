defmodule CodeMySpec.BddRules.Tools.ResolveQuestion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper
  alias CodeMySpec.Questions

  @impl true
  def name, do: "resolve_question"

  @impl true
  def description do
    """
    Marks a Question (red card) as resolved.

    Once resolved, the question no longer counts against the readiness
    gate's `scenarios > questions` clause — the record stays for
    historical context but doesn't block the session.
    """
  end

  @impl true
  def params do
    %{
      question_id:
        {:required, {:meta, :string, [description: "UUID of the question to resolve."]}},
      resolution:
        {:meta, :string,
         [
           description:
             "The answer that resolved it — recorded on the record, not just that it was settled."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:question, %Questions.Question{} = question} <-
           {:question, Questions.get_question(scope, get_param(params, :question_id))},
         {:ok, resolved} <-
           Questions.resolve_question(scope, question, get_param(params, :resolution)) do
      BddRulesMapper.question_resolved_response(resolved)
    else
      {:question, nil} ->
        BddRulesMapper.error(:question_not_found)

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
