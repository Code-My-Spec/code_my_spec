defmodule CodeMySpec.McpServers.Stories.Tools.LinkCriterionToRule do
  @moduledoc """
  Links an existing acceptance criterion to a Three Amigos rule.

  Updates `Criterion.rule_id` only — the criterion's description, kind,
  body, and verification status are untouched. Use after `add_criterion`
  to associate the new criterion with the rule it belongs under (the
  `add_criterion` tool itself only creates the criterion at story level
  and leaves `rule_id` nil).

  Cannot relink verified (locked) criteria. Returns an error if the
  rule_id does not reference an existing rule on this project.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :criterion_id, :string,
      required: true,
      doc: "Criterion ID to relink (from get_story or list_story_titles)"

    field :rule_id, :string,
      required: true,
      doc: "Rule UUID to attach the criterion to (from list_rules)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion(scope, params.criterion_id),
         :ok <- check_not_verified(criterion),
         {:ok, updated} <-
           AcceptanceCriteria.update_criterion(scope, criterion, %{rule_id: params.rule_id}) do
      {:reply, StoriesMapper.criterion_updated_response(updated), frame}
    else
      nil ->
        {:reply, StoriesMapper.criterion_not_found_error(), frame}

      {:error, :criterion_verified} ->
        {:reply,
         StoriesMapper.error(
           "Cannot relink verified criterion. Verified criteria are locked and protected from changes."
         ), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  defp check_not_verified(%{verified: true}), do: {:error, :criterion_verified}
  defp check_not_verified(_), do: :ok
end
