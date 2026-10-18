defmodule CodeMySpec.Stories.Tools.MoveCriterion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "move_criterion"

  @impl true
  def description do
    """
    Moves an acceptance criterion from its current story to a different story.

    Cannot move verified (locked) criteria - they are protected from changes.
    Any existing rule link is cleared during the move, since BDD rules are
    story-scoped and would otherwise point across story boundaries.
    Use get_story to see criterion numbers and their verification status.
    """
  end

  @impl true
  def params do
    %{
      criterion_number:
        {:required, {:meta, :integer, [description: "Criterion number to move (from get_story)"]}},
      target_story_number:
        {:required,
         {:meta, :integer, [description: "Number of the story to move the criterion to"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_number),
         :ok <- check_not_verified(criterion),
         target_story when not is_nil(target_story) <-
           Stories.get_story_by_number(scope, params.target_story_number),
         from_story when not is_nil(from_story) <-
           Stories.get_story(scope, criterion.story_id),
         {:ok, updated} <-
           AcceptanceCriteria.update_criterion(scope, criterion, %{
             story_id: target_story.id,
             rule_id: nil
           }) do
      StoriesMapper.criterion_moved_response(updated, from_story, target_story)
    else
      nil ->
        StoriesMapper.criterion_not_found_error()

      {:error, :criterion_verified} ->
        StoriesMapper.error(
          "Cannot move verified criterion. Verified criteria are locked and protected from changes."
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
