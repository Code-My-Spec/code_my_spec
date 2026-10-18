defmodule CodeMySpec.BddRules.Tools.AddRule do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper

  @impl true
  def name, do: "add_rule"

  @impl true
  def description do
    """
    Adds a Rule (blue card) to a story during a Three Amigos session.

    Rejects when the target story has no personas linked — Three Amigos
    enforces persona linkage before any rules or scenarios can land. The
    agent should call `create_persona` (and `link_persona_to_story` if
    needed) before retrying.
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}},
      statement:
        {:required,
         {:meta, :string,
          [
            description:
              "The rule statement in business terms (e.g., 'Suspended cards cannot be used for purchases'). 1–1000 characters."
          ]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, story} <- Stories.fetch_story_by_number(scope, get_param(params, :story_number)),
         {:ok, rule} <-
           BddRules.create_rule(scope, story.id, %{
             statement: get_param(params, :statement)
           }) do
      BddRulesMapper.rule_response(rule)
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
