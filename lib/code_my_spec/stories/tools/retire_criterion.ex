defmodule CodeMySpec.Stories.Tools.RetireCriterion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Files.SpecCleanup
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "retire_criterion"

  @impl true
  def description do
    """
    Retires an acceptance criterion. There is no delete.

    A retired criterion keeps its number, which is never given to another, and
    drops out of its story's coverage. `restore_criterion` brings it back.
    No file is deleted: the result lists every spex on your working copy that
    now covers nothing (its own, and any other naming a number that is not a
    live criterion). Delete those in your copy and commit.
    """
  end

  @impl true
  def params do
    %{
      criterion_number:
        {:required,
         {:meta, :integer, [description: "Criterion number to retire (from get_story)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, params.criterion_number),
         :ok <- check_not_verified(criterion),
         {:ok, retired} <- AcceptanceCriteria.retire_criterion(scope, criterion) do
      StoriesMapper.criterion_retired_response(retired, SpecCleanup.orphans(scope))
    else
      nil ->
        StoriesMapper.criterion_not_found_error()

      {:error, :criterion_verified} ->
        StoriesMapper.error("Cannot retire a verified criterion. Verified criteria are locked.")

      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end

  defp check_not_verified(%{verified: true}), do: {:error, :criterion_verified}
  defp check_not_verified(_), do: :ok
end
