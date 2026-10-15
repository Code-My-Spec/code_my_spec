defmodule CodeMySpec.McpServers.Stories.Tools.RestoreCriterion do
  @moduledoc """
  Brings a retired acceptance criterion back, under the same number.

  A spec file that names the number covers it again.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories.AcceptanceCriteria

  schema do
    field :criterion_number, :integer,
      required: true,
      description: "Criterion number to restore (from get_criterion)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_number),
         {:ok, restored} <- AcceptanceCriteria.restore_criterion(scope, criterion) do
      {:reply, StoriesMapper.criterion_restored_response(restored), frame}
    else
      nil ->
        {:reply, StoriesMapper.criterion_not_found_error(), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
