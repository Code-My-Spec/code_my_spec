defmodule CodeMySpec.McpServers.Stories.Tools.MoveCriterion do
  @moduledoc """
  Moves an acceptance criterion from its current story to a different story.

  Cannot move verified (locked) criteria - they are protected from changes.
  Any existing rule link is cleared during the move, since BDD rules are
  story-scoped and would otherwise point across story boundaries.
  Use get_story to see criteria IDs and their verification status.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :criterion_id, :string,
      required: true,
      doc: "Criterion ID to move (from get_story response)"

    field :target_story_id, :string,
      required: true,
      doc: "Story ID to move the criterion to"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion(scope, params.criterion_id),
         :ok <- check_not_verified(criterion),
         target_story when not is_nil(target_story) <-
           Stories.get_story(scope, params.target_story_id),
         from_story when not is_nil(from_story) <-
           Stories.get_story(scope, criterion.story_id),
         {:ok, updated} <-
           AcceptanceCriteria.update_criterion(scope, criterion, %{
             story_id: target_story.id,
             rule_id: nil
           }) do
      {:reply, StoriesMapper.criterion_moved_response(updated, from_story, target_story), frame}
    else
      nil ->
        {:reply, StoriesMapper.criterion_not_found_error(), frame}

      {:error, :criterion_verified} ->
        {:reply,
         StoriesMapper.error(
           "Cannot move verified criterion. Verified criteria are locked and protected from changes."
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
