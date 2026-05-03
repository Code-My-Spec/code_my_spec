defmodule CodeMySpec.McpServers.Stories.Tools.UpdateCriterion do
  @moduledoc """
  Updates the description of an existing acceptance criterion.

  Cannot update verified (locked) criteria - they are protected from changes.
  Use get_story to see criteria IDs and their verification status.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :criterion_id, :string,
      required: true,
      doc: "Criterion ID to update (from get_story response)"

    field :description, :string, required: true, doc: "New description text"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion(scope, params.criterion_id),
         :ok <- check_not_verified(criterion),
         {:ok, updated} <-
           AcceptanceCriteria.update_criterion(scope, criterion, %{
             description: params.description
           }) do
      {:reply, StoriesMapper.criterion_updated_response(updated), frame}
    else
      nil ->
        {:reply, StoriesMapper.criterion_not_found_error(), frame}

      {:error, :criterion_verified} ->
        {:reply,
         StoriesMapper.error(
           "Cannot update verified criterion. Verified criteria are locked and protected from changes."
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
