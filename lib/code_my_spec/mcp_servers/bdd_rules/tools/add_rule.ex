defmodule CodeMySpec.McpServers.BddRules.Tools.AddRule do
  @moduledoc """
  Adds a Rule (blue card) to a story during a Three Amigos session.

  Rejects when the target story has no personas linked — Three Amigos
  enforces persona linkage before any rules or scenarios can land. The
  agent should call `create_persona` (and `link_persona_to_story` if
  needed) before retrying.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.BddRules
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :story_id, :integer, required: true, doc: "ID of the story to add the rule to."

    field :statement, :string,
      required: true,
      doc:
        "The rule statement in business terms (e.g., 'Suspended cards cannot be used for purchases'). 1–1000 characters."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, rule} <-
           BddRules.create_rule(scope, get_param(params, :story_id), %{
             statement: get_param(params, :statement)
           }) do
      {:reply, BddRulesMapper.rule_response(rule), frame}
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
