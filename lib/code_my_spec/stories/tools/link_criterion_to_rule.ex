defmodule CodeMySpec.Stories.Tools.LinkCriterionToRule do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "link_criterion_to_rule"

  @impl true
  def description do
    """
    Links an existing acceptance criterion to a Three Amigos rule.

    Updates `Criterion.rule_id` only — the criterion's description, kind,
    body, and verification status are untouched. Use after `add_criterion`
    to associate the new criterion with the rule it belongs under (the
    `add_criterion` tool itself only creates the criterion at story level
    and leaves `rule_id` nil).

    Cannot relink verified (locked) criteria. Returns an error if the
    rule_id does not reference an existing rule on this project.
    """
  end

  @impl true
  def params do
    %{
      criterion_number:
        {:required,
         {:meta, :integer, [description: "Criterion number to relink (from get_story)"]}},
      rule_id:
        {:required,
         {:meta, :string, [description: "Rule UUID to attach the criterion to (from list_rules)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_number),
         :ok <- check_not_verified(criterion),
         {:ok, updated} <-
           AcceptanceCriteria.update_criterion(scope, criterion, %{rule_id: params.rule_id}) do
      StoriesMapper.criterion_updated_response(updated)
    else
      nil ->
        StoriesMapper.criterion_not_found_error()

      {:error, :criterion_verified} ->
        StoriesMapper.error(
          "Cannot relink verified criterion. Verified criteria are locked and protected from changes."
        )

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end

  defp check_not_verified(%{verified: true}), do: {:error, :criterion_verified}
  defp check_not_verified(_), do: :ok
end
