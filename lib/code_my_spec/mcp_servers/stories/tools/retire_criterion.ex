defmodule CodeMySpec.McpServers.Stories.Tools.RetireCriterion do
  @moduledoc """
  Retires an acceptance criterion. There is no delete.

  A retired criterion keeps its number, which is never given to another, and
  drops out of its story's coverage. `restore_criterion` brings it back.
  A spec file naming it is not touched; delete it if it no longer applies.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :criterion_id, :string,
      required: true,
      doc: "Criterion number to retire (from get_story)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_id),
         :ok <- check_not_verified(criterion),
         {:ok, retired} <- AcceptanceCriteria.retire_criterion(scope, criterion) do
      {:reply, StoriesMapper.criterion_retired_response(retired), frame}
    else
      nil ->
        {:reply, StoriesMapper.criterion_not_found_error(), frame}

      {:error, :criterion_verified} ->
        {:reply,
         StoriesMapper.error("Cannot retire a verified criterion. Verified criteria are locked."),
         frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  defp check_not_verified(%{verified: true}), do: {:error, :criterion_verified}
  defp check_not_verified(_), do: :ok
end
