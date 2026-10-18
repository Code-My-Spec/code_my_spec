defmodule CodeMySpec.Stories.Tools.RestoreCriterion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "restore_criterion"

  @impl true
  def description do
    """
    Brings a retired acceptance criterion back, under the same number.

    A spec file that names the number covers it again.
    """
  end

  @impl true
  def params do
    %{
      criterion_number:
        {:required,
         {:meta, :integer, [description: "Criterion number to restore (from get_criterion)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_number),
         {:ok, restored} <- AcceptanceCriteria.restore_criterion(scope, criterion) do
      StoriesMapper.criterion_restored_response(restored)
    else
      nil ->
        StoriesMapper.criterion_not_found_error()

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
